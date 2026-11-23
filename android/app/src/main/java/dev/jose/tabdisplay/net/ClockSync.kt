package dev.jose.tabdisplay.net

/**
 * Estima el offset entre el reloj de la Mac y el de la tablet con PING/PONG
 * (PROTOCOL.md, "Medición de latencia"). offset = relojMac − relojTablet.
 */
class ClockSync(private val window: Int = 10) {
    private val offsets = ArrayDeque<Long>()
    private val rtts = ArrayDeque<Long>()

    /**
     * @param nowUs reloj de la tablet al recibir el PONG
     * @param echoUs timestamp del PING original (reloj de la tablet)
     * @param macUs timestampUs del encabezado del PONG (reloj de la Mac)
     */
    @Synchronized
    fun onPong(nowUs: Long, echoUs: Long, macUs: Long) {
        val rtt = nowUs - echoUs
        if (rtt < 0 || rtt > 5_000_000) return // eco inválido o de otra sesión
        offsets.addLast(macUs - (echoUs + rtt / 2))
        rtts.addLast(rtt)
        while (offsets.size > window) offsets.removeFirst()
        while (rtts.size > window) rtts.removeFirst()
    }

    @Synchronized
    fun reset() {
        offsets.clear()
        rtts.clear()
    }

    /** Mediana del offset, o null si aún no hay muestras. */
    @get:Synchronized
    val offsetUs: Long?
        get() = median(offsets)

    @get:Synchronized
    val rttUs: Long?
        get() = median(rtts)

    /** Convierte un timestamp de la Mac al reloj de la tablet, si ya hay estimación. */
    fun macToLocalUs(macUs: Long): Long? = offsetUs?.let { macUs - it }

    private fun median(values: Collection<Long>): Long? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2
    }
}
