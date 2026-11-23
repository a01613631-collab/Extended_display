package dev.jose.tabdisplay.net

/**
 * Estima el offset entre el reloj de la Mac y el de la tablet con PING/PONG
 * (PROTOCOL.md, "Medición de latencia"). offset = relojMac − relojTablet.
 *
 * El PONG viaja por el mismo socket que el video: si hay cuadros en camino llega tarde y el
 * retraso es asimétrico, lo que sesga el offset hasta RTT/2. Por eso (como NTP) se usa el offset
 * de la muestra con MENOR RTT de la ventana: es la que menos esperó en fila.
 */
class ClockSync(private val window: Int = 30) {
    private class Sample(val rttUs: Long, val offsetUs: Long)

    private val samples = ArrayDeque<Sample>()

    /**
     * @param nowUs reloj de la tablet al recibir el PONG
     * @param echoUs timestamp del PING original (reloj de la tablet)
     * @param macUs timestampUs del encabezado del PONG (reloj de la Mac)
     */
    @Synchronized
    fun onPong(nowUs: Long, echoUs: Long, macUs: Long) {
        val rtt = nowUs - echoUs
        if (rtt < 0 || rtt > 5_000_000) return // eco inválido o de otra sesión
        samples.addLast(Sample(rtt, macUs - (echoUs + rtt / 2)))
        while (samples.size > window) samples.removeFirst()
    }

    @Synchronized
    fun reset() {
        samples.clear()
    }

    /** Offset de la muestra con menor RTT (la más reciente si hay empate), o null sin muestras. */
    @get:Synchronized
    val offsetUs: Long?
        get() {
            var best: Sample? = null
            for (sample in samples) {
                if (best == null || sample.rttUs <= best.rttUs) best = sample
            }
            return best?.offsetUs
        }

    /** Mediana del RTT de las últimas 10 muestras (para mostrar). */
    @get:Synchronized
    val rttUs: Long?
        get() {
            if (samples.isEmpty()) return null
            val recent = samples.toList().takeLast(10).map { it.rttUs }.sorted()
            val mid = recent.size / 2
            return if (recent.size % 2 == 1) recent[mid] else (recent[mid - 1] + recent[mid]) / 2
        }

    /** Convierte un timestamp de la Mac al reloj de la tablet, si ya hay estimación. */
    fun macToLocalUs(macUs: Long): Long? = offsetUs?.let { macUs - it }
}
