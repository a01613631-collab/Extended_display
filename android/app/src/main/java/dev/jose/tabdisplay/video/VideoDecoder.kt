package dev.jose.tabdisplay.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Surface
import dev.jose.tabdisplay.net.ClockSync
import dev.jose.tabdisplay.net.StreamStats
import java.io.DataInputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * MediaCodec en modo asíncrono con salida directa al Surface del SurfaceView.
 *
 * Reglas de hilos:
 * - Todo el ciclo de vida del códec (crear, flush, liberar) ocurre en el hilo de red,
 *   que es el único que llama a onCodecConfig/onFrame/release.
 * - Los callbacks de MediaCodec corren en [thread] y solo devuelven índices y renderizan.
 */
class VideoDecoder(
    private val surface: Surface,
    private val mime: String,
    private val width: Int,
    private val height: Int,
    private val stats: StreamStats,
    private val clock: ClockSync,
    private val requestKeyframe: () -> Unit,
) {
    private val thread = HandlerThread("TabDisplay-decoder", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)

    @Volatile private var codec: MediaCodec? = null
    private val freeInputs = LinkedBlockingQueue<Int>()

    // PTS de cuadros entregados al decodificador que aún no salen: mide el atraso sin acumular errores.
    private val inFlight = ArrayDeque<Long>()
    private val inFlightLock = Any()

    private var config: ByteArray? = null
    private var waitingForKeyframe = true
    private var scratch = ByteArray(1 shl 20)

    @Volatile private var needsFlush = false
    @Volatile private var needsRecreate = false

    // Solo los usa el hilo del decodificador.
    private val pendingOutputs = ArrayList<Int>()
    private var drainPosted = false

    val name: String get() = stats.decoderName

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
            if (mc === codec) freeInputs.offer(index)
        }

        override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (mc !== codec) return
            synchronized(inFlightLock) {
                while (inFlight.isNotEmpty() && inFlight.first() <= info.presentationTimeUs) inFlight.removeFirst()
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 || info.size == 0 && info.flags != 0) {
                runCatching { mc.releaseOutputBuffer(index, false) }
                return
            }
            // Si ya hay callbacks de salida en la cola del Handler, se procesan antes que drain:
            // así, cuando salen varios cuadros juntos, solo se renderiza el último.
            pendingOutputs.add(index)
            if (!drainPosted) {
                drainPosted = true
                handler.post(drain)
            }
        }

        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            if (mc !== codec) return
            Log.w(TAG, "Error del decodificador (transient=${e.isTransient}, recoverable=${e.isRecoverable})", e)
            if (e.isTransient) return
            if (e.isRecoverable) needsFlush = true else needsRecreate = true
        }

        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "Formato de salida: $format")
        }
    }

    private val drain = Runnable {
        drainPosted = false
        val mc = codec
        val count = pendingOutputs.size
        for (i in 0 until count) {
            val render = i == count - 1
            try {
                if (render) {
                    // "Muéstralo ya": con releaseOutputBuffer(index, true) Android usaría el PTS como
                    // hora de presentación, y el PTS viene del reloj de la Mac (días "en el futuro").
                    mc?.releaseOutputBuffer(pendingOutputs[i], System.nanoTime())
                } else {
                    mc?.releaseOutputBuffer(pendingOutputs[i], false)
                    stats.framesDropped.incrementAndGet()
                }
            } catch (e: IllegalStateException) {
                // Índice de antes de un flush: se ignora.
            }
        }
        pendingOutputs.clear()
    }

    private var renderedForLog = 0

    private val frameRenderedListener = MediaCodec.OnFrameRenderedListener { _, presentationTimeUs, nanoTime ->
        stats.framesRendered.incrementAndGet()
        val offset = clock.offsetUs
        val latencyUs = offset?.let { nanoTime / 1000 - (presentationTimeUs - it) }
        if (latencyUs != null) stats.addLatencySample(latencyUs)
        // Diagnóstico cada ~5 s: valores crudos para verificar el cálculo de latencia.
        if (++renderedForLog % 300 == 1) {
            Log.i(TAG, "latencia: pts=$presentationTimeUs renderUs=${nanoTime / 1000} offsetUs=$offset → ${latencyUs?.let { it / 1000 }} ms")
        }
    }

    /** Llega antes de cada keyframe. Si cambió, se recrea el decodificador. */
    fun onCodecConfig(data: ByteArray) {
        val same = config?.contentEquals(data) == true && codec != null
        if (same && !waitingForKeyframe) return
        if (!same) {
            config = data
            // La Mac manda el keyframe justo después del CODEC_CONFIG: no hace falta pedirlo.
            recreate(askForKeyframe = false)
        }
        // Tras crear o tras un flush, el decodificador necesita SPS/PPS otra vez.
        queue(data, data.size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
    }

    /** Lee el payload del VIDEO_FRAME directamente del socket y lo entrega al decodificador. */
    fun onFrame(input: DataInputStream, length: Int, keyframe: Boolean, ptsUs: Long) {
        if (scratch.size < length) scratch = ByteArray(length + length / 4)
        // Siempre se consume el payload completo para no desalinear el stream.
        input.readFully(scratch, 0, length)

        if (needsRecreate) {
            recreate(askForKeyframe = true)
            config?.let { queue(it, it.size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG) }
            return
        }
        if (needsFlush) {
            flushAndWaitForKeyframe("error recuperable")
            return
        }
        if (codec == null || (waitingForKeyframe && !keyframe)) {
            stats.framesDropped.incrementAndGet()
            return
        }
        val pending = synchronized(inFlightLock) { inFlight.size }
        if (pending > MAX_IN_FLIGHT) {
            stats.framesDropped.incrementAndGet()
            flushAndWaitForKeyframe("decodificador atrasado ($pending cuadros)")
            return
        }
        if (queue(scratch, length, ptsUs, if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)) {
            synchronized(inFlightLock) { inFlight.addLast(ptsUs) }
            if (keyframe) waitingForKeyframe = false
        }
    }

    private fun queue(data: ByteArray, length: Int, ptsUs: Long, flags: Int): Boolean {
        val mc = codec ?: return false
        val index = freeInputs.poll(INPUT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (index == null) {
            stats.framesDropped.incrementAndGet()
            flushAndWaitForKeyframe("sin buffers de entrada")
            return false
        }
        return try {
            val buffer = mc.getInputBuffer(index) ?: throw IllegalStateException("buffer nulo")
            buffer.clear()
            if (length > buffer.capacity()) {
                Log.w(TAG, "Cuadro de $length bytes no cabe en el buffer (${buffer.capacity()})")
                mc.queueInputBuffer(index, 0, 0, ptsUs, 0)
                flushAndWaitForKeyframe("cuadro demasiado grande")
                return false
            }
            buffer.put(data, 0, length)
            mc.queueInputBuffer(index, 0, length, ptsUs, flags)
            true
        } catch (e: IllegalStateException) {
            Log.w(TAG, "No se pudo encolar el cuadro", e)
            needsFlush = true
            false
        }
    }

    private fun flushAndWaitForKeyframe(reason: String) {
        Log.i(TAG, "Vaciando decodificador: $reason")
        needsFlush = false
        val mc = codec
        if (mc != null) {
            try {
                mc.flush()
                freeInputs.clear()
                synchronized(inFlightLock) { inFlight.clear() }
                mc.start() // en modo asíncrono hay que reanudar tras flush()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "flush falló; se recrea el decodificador", e)
                needsRecreate = true
            }
        }
        waitingForKeyframe = true
        requestKeyframe()
    }

    private fun recreate(askForKeyframe: Boolean) {
        releaseCodec()
        needsFlush = false
        needsRecreate = false
        waitingForKeyframe = true
        codec = createCodec()
        if (askForKeyframe) requestKeyframe()
    }

    private fun createCodec(): MediaCodec? {
        val info = findDecoder(mime)
        // Primer intento con todas las optimizaciones; si el códec rechaza alguna clave, uno mínimo.
        for (lowLatencyKeys in listOf(true, false)) {
            val mc = try {
                if (info != null) MediaCodec.createByCodecName(info.name) else MediaCodec.createDecoderByType(mime)
            } catch (e: Exception) {
                Log.e(TAG, "No hay decodificador para $mime", e)
                return null
            }
            try {
                val format = MediaFormat.createVideoFormat(mime, width, height)
                format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
                if (lowLatencyKeys) {
                    val supportsLowLatency = info?.getCapabilitiesForType(mime)
                        ?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency) == true
                    if (supportsLowLatency) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                    format.setInteger(MediaFormat.KEY_PRIORITY, 0) // tiempo real
                    format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
                    // Claves de Qualcomm (Snapdragon): baja latencia y salida en orden de decodificación.
                    format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                    format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
                }
                mc.setCallback(callback, handler)
                mc.setOnFrameRenderedListener(frameRenderedListener, handler)
                // codec se asigna antes de start() para que los primeros callbacks no se descarten.
                codec = mc
                mc.configure(format, surface, null, 0)
                mc.start()
                stats.decoderName = mc.name
                Log.i(TAG, "Decodificador ${mc.name} ${width}x$height lowLatencyKeys=$lowLatencyKeys")
                return mc
            } catch (e: Exception) {
                Log.w(TAG, "configure falló (lowLatencyKeys=$lowLatencyKeys)", e)
                codec = null
                freeInputs.clear()
                runCatching { mc.release() }
            }
        }
        return null
    }

    private fun releaseCodec() {
        val mc = codec ?: return
        codec = null
        runCatching { mc.stop() }
        runCatching { mc.release() }
        freeInputs.clear()
        synchronized(inFlightLock) { inFlight.clear() }
        handler.post { pendingOutputs.clear() }
    }

    fun release() {
        releaseCodec()
        thread.quitSafely()
    }

    companion object {
        private const val TAG = "TabDisplay"
        private const val MAX_IN_FLIGHT = 6
        private const val INPUT_TIMEOUT_MS = 100L

        /** Decodificador por hardware para [mime], o null. */
        fun findDecoder(mime: String): MediaCodecInfo? =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                !info.isEncoder && info.isHardwareAccelerated &&
                    info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }
    }
}
