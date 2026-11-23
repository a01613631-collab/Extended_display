package dev.jose.tabdisplay.net

import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

/** Contadores de la sesión. Se escriben desde varios hilos y se leen una vez por segundo. */
class StreamStats {
    val bytesReceived = AtomicLong()
    val framesReceived = AtomicLong()
    val framesRendered = AtomicLong()
    val framesDropped = AtomicLong()
    private val latencySumUs = AtomicLong()
    private val latencyCount = AtomicLong()

    @Volatile var decoderName: String = ""

    private var lastBytes = 0L
    private var lastReceived = 0L
    private var lastRendered = 0L
    private var lastTimeUs = 0L

    data class Snapshot(
        val fpsReceived: Double,
        val fpsRendered: Double,
        val mbps: Double,
        val rttMs: Double?,
        val latencyMs: Double?,
        val droppedFrames: Long,
        val decoder: String,
    ) {
        fun toJson(): ByteArray {
            val json = JSONObject()
                .put("fpsReceived", round1(fpsReceived))
                .put("fpsRendered", round1(fpsRendered))
                .put("mbps", round1(mbps))
                .put("droppedFrames", droppedFrames)
                .put("decoder", decoder)
            rttMs?.let { json.put("rttMs", round1(it)) }
            latencyMs?.let { json.put("latencyMs", round1(it)) }
            return json.toString().toByteArray(Charsets.UTF_8)
        }

        private fun round1(value: Double) = Math.round(value * 10.0) / 10.0
    }

    fun reset() {
        bytesReceived.set(0)
        framesReceived.set(0)
        framesRendered.set(0)
        framesDropped.set(0)
        latencySumUs.set(0)
        latencyCount.set(0)
        lastBytes = 0
        lastReceived = 0
        lastRendered = 0
        lastTimeUs = Protocol.nowUs()
    }

    fun addLatencySample(latencyUs: Long) {
        // Descarta valores absurdos (offset aún no estable o cuadro de "refresco").
        if (latencyUs < 0 || latencyUs > 2_000_000) return
        latencySumUs.addAndGet(latencyUs)
        latencyCount.incrementAndGet()
    }

    /** Calcula tasas desde el snapshot anterior. Llamar desde un solo hilo. */
    fun snapshot(rttUs: Long?): Snapshot {
        val now = Protocol.nowUs()
        val seconds = ((now - lastTimeUs).coerceAtLeast(1)) / 1_000_000.0
        val bytes = bytesReceived.get()
        val received = framesReceived.get()
        val rendered = framesRendered.get()
        val latencyN = latencyCount.getAndSet(0)
        val latencySum = latencySumUs.getAndSet(0)
        val snapshot = Snapshot(
            fpsReceived = (received - lastReceived) / seconds,
            fpsRendered = (rendered - lastRendered) / seconds,
            mbps = (bytes - lastBytes) * 8.0 / seconds / 1_000_000.0,
            rttMs = rttUs?.let { it / 1000.0 },
            latencyMs = if (latencyN > 0) latencySum.toDouble() / latencyN / 1000.0 else null,
            droppedFrames = framesDropped.get(),
            decoder = decoderName,
        )
        lastBytes = bytes
        lastReceived = received
        lastRendered = rendered
        lastTimeUs = now
        return snapshot
    }
}
