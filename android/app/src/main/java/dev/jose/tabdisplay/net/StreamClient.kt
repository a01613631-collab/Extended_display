package dev.jose.tabdisplay.net

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Process
import android.util.Log
import android.view.Surface
import dev.jose.tabdisplay.AppPrefs
import dev.jose.tabdisplay.DeviceInfo
import dev.jose.tabdisplay.video.VideoDecoder
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

enum class Transport(val wireName: String) { USB("usb"), WIFI("wifi") }

data class SessionInfo(
    val transport: Transport,
    val codec: String,
    val widthPx: Int,
    val heightPx: Int,
    val fps: Int,
    val bitrate: Int,
    val macName: String?,
)

/**
 * Cliente TCP de la tablet. Un hilo de red conecta (USB primero, luego Wi-Fi), hace el
 * handshake y lee mensajes; un hilo emisor por sesión escribe toques, PING y STATS.
 */
class StreamClient(
    context: Context,
    private val prefs: AppPrefs,
    private val device: DeviceInfo,
    private val listener: Listener,
) {
    interface Listener {
        /** Sin sesión. [message] es un texto para mostrar o null para el mensaje por defecto. */
        fun onWaiting(message: String?)
        fun onSessionStarted(session: SessionInfo)
        fun onSessionEnded()
        /** La Mac rechazó el token Wi-Fi: el emparejamiento se borró. */
        fun onPairingInvalid()
    }

    private val appContext = context.applicationContext
    private val discovery = MacDiscovery(appContext)
    private val wifiManager = appContext.getSystemService(WifiManager::class.java)

    val stats = StreamStats()
    val clock = ClockSync()

    @Volatile private var running = false
    @Volatile private var surface: Surface? = null
    @Volatile private var socket: Socket? = null
    @Volatile private var outQueue: ArrayBlockingQueue<ByteArray>? = null
    @Volatile var lastSnapshot: StreamStats.Snapshot? = null
        private set
    @Volatile var session: SessionInfo? = null
        private set
    private var thread: Thread? = null
    private var lastKeyframeRequestUs = 0L

    fun start(surface: Surface) {
        if (running) return
        this.surface = surface
        running = true
        if (prefs.wifiEnabled && prefs.pairingToken != null) discovery.start()
        thread = Thread(::connectLoop, "TabDisplay-net").also { it.start() }
    }

    fun stop() {
        if (!running) return
        running = false
        // El BYE lo escribe el hilo emisor (único escritor del socket); el cierre va en otro hilo
        // porque no se puede tocar un socket desde el hilo de UI.
        val sock = socket
        if (sock != null) {
            send(MsgType.BYE, byteArrayOf(ByeReason.NORMAL.toByte()))
            val closer = Thread {
                runCatching { Thread.sleep(100) }
                runCatching { sock.close() }
            }
            closer.start()
            closer.join(300)
        }
        thread?.interrupt()
        thread?.join(2000)
        thread = null
        discovery.stop()
        surface = null
    }

    /** Llamar si cambian los ajustes de Wi-Fi o el emparejamiento. */
    fun onWifiSettingsChanged() {
        if (!running) return
        if (prefs.wifiEnabled && prefs.pairingToken != null) discovery.start() else discovery.stop()
    }

    // --- Envío (seguro desde cualquier hilo, nunca bloquea) ---

    fun sendTouch(payload: ByteArray) = send(MsgType.TOUCH, payload)

    fun sendScroll(payload: ByteArray) = send(MsgType.SCROLL, payload)

    fun requestKeyframe() {
        val now = Protocol.nowUs()
        // Varias causas pueden pedirlo a la vez; con una petición cada 200 ms basta.
        if (now - lastKeyframeRequestUs < 200_000) return
        lastKeyframeRequestUs = now
        send(MsgType.KEYFRAME_REQUEST, null)
    }

    private fun send(type: Int, payload: ByteArray?) {
        // Cola acotada: si está llena (red caída) se descarta el mensaje en lugar de crecer.
        outQueue?.offer(Protocol.encode(type, Protocol.nowUs(), payload))
    }

    // --- Conexión ---

    private fun connectLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
        var delayMs = 0L
        while (running) {
            if (delayMs > 0 && !sleep(delayMs)) break
            delayMs = RETRY_DELAY_MS
            val (sock, transport) = connectAny() ?: continue
            socket = sock
            try {
                delayMs = runSession(sock, transport)
            } catch (e: EOFException) {
                Log.i(TAG, "La Mac cerró la conexión")
            } catch (e: SocketTimeoutException) {
                Log.w(TAG, "Sin datos de la Mac en ${READ_TIMEOUT_MS / 1000} s; reconectando")
            } catch (e: IOException) {
                if (running) Log.w(TAG, "Conexión perdida: ${e.message}")
            } finally {
                socket = null
                runCatching { sock.close() }
            }
        }
    }

    private fun connectAny(): Pair<Socket, Transport>? {
        tryConnect(InetSocketAddress(LOOPBACK, Protocol.DEFAULT_PORT), USB_CONNECT_TIMEOUT_MS)
            ?.let { return it to Transport.USB }
        if (prefs.wifiEnabled && prefs.pairingToken != null) {
            discovery.latest?.let { address ->
                tryConnect(address, WIFI_CONNECT_TIMEOUT_MS)?.let { return it to Transport.WIFI }
            }
        }
        return null
    }

    private fun tryConnect(address: InetSocketAddress, timeoutMs: Int): Socket? {
        val sock = Socket()
        return try {
            sock.tcpNoDelay = true
            sock.connect(address, timeoutMs)
            sock
        } catch (e: IOException) {
            runCatching { sock.close() }
            null
        }
    }

    /** Ejecuta una sesión completa. Devuelve cuántos ms esperar antes de reconectar. */
    private fun runSession(sock: Socket, transport: Transport): Long {
        sock.soTimeout = READ_TIMEOUT_MS
        val input = DataInputStream(BufferedInputStream(sock.getInputStream(), 256 * 1024))
        val output = sock.getOutputStream()

        // HELLO debe ser el PRIMER mensaje (PROTOCOL.md): se escribe aquí, antes de arrancar el
        // hilo emisor, que manda PING en cuanto empieza.
        val token = if (transport == Transport.WIFI) prefs.pairingToken else null
        val hello = Hello(
            device.deviceName, device.widthPx, device.heightPx, device.densityDpi,
            device.refreshRates, device.codecs, transport.wireName, token,
        )
        output.write(Protocol.encode(MsgType.HELLO, Protocol.nowUs(), hello.toJson()))

        val queue = ArrayBlockingQueue<ByteArray>(OUT_QUEUE_CAPACITY)
        outQueue = queue
        val sender = Thread({ senderLoop(output, queue) }, "TabDisplay-send")
        sender.start()

        var decoder: VideoDecoder? = null
        var wifiLock: WifiManager.WifiLock? = null
        var started = false
        try {
            val headerScratch = ByteArray(Protocol.HEADER_SIZE)
            val first = Protocol.readHeader(input, headerScratch)
            if (first.type == MsgType.BYE) return handleBye(input, first, transport)
            if (first.type != MsgType.HELLO_ACK) throw ProtocolException("se esperaba HELLO_ACK, llegó ${first.type}")
            val ack = HelloAck.parse(Protocol.readPayload(input, first.length))
            if (!ack.accepted) {
                Log.w(TAG, "Rechazado por la Mac: ${ack.reason}")
                listener.onWaiting(ack.reason ?: "rechazado")
                // Normalmente sigue un BYE con el motivo exacto.
                return runCatching {
                    val bye = Protocol.readHeader(input, headerScratch)
                    if (bye.type == MsgType.BYE) handleBye(input, bye, transport) else REJECTED_DELAY_MS
                }.getOrDefault(REJECTED_DELAY_MS)
            }
            if (ack.streamWidthPx <= 0 || ack.streamHeightPx <= 0) throw ProtocolException("tamaño de stream inválido")
            if (transport == Transport.USB && ack.pairingToken != null) {
                prefs.savePairing(ack.pairingToken, ack.macName)
                // Ya emparejada: si luego se desconecta el cable, puede seguir por Wi-Fi sin esperar.
                if (prefs.wifiEnabled) discovery.start()
            }

            val surface = surface ?: return RETRY_DELAY_MS
            clock.reset()
            stats.reset()
            decoder = VideoDecoder(
                surface, ack.codec, ack.streamWidthPx, ack.streamHeightPx, stats, clock, ::requestKeyframe,
            )
            if (transport == Transport.WIFI) {
                wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "TabDisplay").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            val info = SessionInfo(
                transport, ack.codec, ack.streamWidthPx, ack.streamHeightPx, ack.fps, ack.bitrate, ack.macName,
            )
            session = info
            started = true
            Log.i(TAG, "Sesión iniciada: $info")
            listener.onSessionStarted(info)

            while (running) {
                val header = Protocol.readHeader(input, headerScratch)
                when (header.type) {
                    MsgType.VIDEO_FRAME -> {
                        stats.framesReceived.incrementAndGet()
                        stats.bytesReceived.addAndGet((header.length + Protocol.HEADER_SIZE).toLong())
                        decoder.onFrame(input, header.length, header.isKeyframe, header.timestampUs)
                    }
                    MsgType.CODEC_CONFIG -> decoder.onCodecConfig(Protocol.readPayload(input, header.length))
                    MsgType.PING -> {
                        input.skipFully(header.length)
                        send(MsgType.PONG, Protocol.encodeLong(header.timestampUs))
                    }
                    MsgType.PONG -> {
                        val echo = Protocol.decodeLong(Protocol.readPayload(input, header.length))
                        clock.onPong(Protocol.nowUs(), echo, header.timestampUs)
                    }
                    MsgType.BYE -> return handleBye(input, header, transport)
                    else -> input.skipFully(header.length) // tipo desconocido: se ignora
                }
            }
            return 0
        } catch (e: ProtocolException) {
            Log.w(TAG, "Error de protocolo: ${e.message}")
            sendBye(sock, ByeReason.PROTOCOL_ERROR)
            return RETRY_DELAY_MS
        } finally {
            outQueue = null
            sender.interrupt()
            decoder?.release()
            wifiLock?.release()
            session = null
            lastSnapshot = null
            if (started) listener.onSessionEnded()
        }
    }

    private fun handleBye(input: DataInputStream, header: Header, transport: Transport): Long {
        val payload = Protocol.readPayload(input, header.length)
        val reason = if (payload.isNotEmpty()) payload[0].toInt() and 0xFF else ByeReason.NORMAL
        Log.i(TAG, "BYE de la Mac, motivo $reason")
        return when (reason) {
            ByeReason.RECONFIGURE -> 0
            ByeReason.UNAUTHORIZED -> {
                if (transport == Transport.WIFI) {
                    prefs.clearPairing()
                    discovery.stop()
                    listener.onPairingInvalid()
                }
                REJECTED_DELAY_MS
            }
            ByeReason.VERSION_MISMATCH, ByeReason.REPLACED -> REJECTED_DELAY_MS
            else -> RETRY_DELAY_MS
        }
    }

    private fun sendBye(sock: Socket, reason: Int) {
        runCatching {
            sock.getOutputStream().write(Protocol.encode(MsgType.BYE, Protocol.nowUs(), byteArrayOf(reason.toByte())))
        }
    }

    private fun senderLoop(output: OutputStream, queue: ArrayBlockingQueue<ByteArray>) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
        var nextPingUs = Protocol.nowUs()
        var nextStatsUs = nextPingUs + 1_000_000
        try {
            while (!Thread.currentThread().isInterrupted) {
                val now = Protocol.nowUs()
                if (now >= nextPingUs) {
                    output.write(Protocol.encode(MsgType.PING, now))
                    nextPingUs = now + PING_INTERVAL_US
                }
                if (now >= nextStatsUs) {
                    val snapshot = stats.snapshot(clock.rttUs)
                    lastSnapshot = snapshot
                    output.write(Protocol.encode(MsgType.STATS, now, snapshot.toJson()))
                    nextStatsUs = now + 1_000_000
                }
                val waitUs = (minOf(nextPingUs, nextStatsUs) - Protocol.nowUs()).coerceAtLeast(0)
                val message = queue.poll(waitUs, TimeUnit.MICROSECONDS) ?: continue
                output.write(message)
            }
        } catch (e: InterruptedException) {
            // Fin de la sesión.
        } catch (e: IOException) {
            // Si falla la escritura, se cierra el socket para que el hilo lector termine también.
            socket?.let { runCatching { it.close() } }
        }
        // Lo que quede (p. ej. un BYE) se intenta mandar antes de salir.
        while (true) {
            val message = queue.poll() ?: break
            runCatching { output.write(message) }
        }
    }

    private fun sleep(ms: Long): Boolean = try {
        Thread.sleep(ms)
        true
    } catch (e: InterruptedException) {
        false
    }

    private fun DataInputStream.skipFully(count: Int) {
        var remaining = count
        while (remaining > 0) {
            val skipped = skipBytes(remaining)
            if (skipped <= 0) {
                readByte() // lanza EOFException si se cerró
                remaining--
            } else {
                remaining -= skipped
            }
        }
    }

    companion object {
        private const val TAG = "TabDisplay"
        private const val LOOPBACK = "127.0.0.1"
        private const val RETRY_DELAY_MS = 500L
        private const val REJECTED_DELAY_MS = 3000L
        private const val USB_CONNECT_TIMEOUT_MS = 400
        private const val WIFI_CONNECT_TIMEOUT_MS = 1500
        private const val READ_TIMEOUT_MS = 5000
        private const val PING_INTERVAL_US = 1_000_000L
        private const val OUT_QUEUE_CAPACITY = 512
    }
}
