package dev.jose.tabdisplay.input

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.pow

/**
 * Inercia del scroll: la velocidad decae exponencialmente (factor por milisegundo, como en iOS/macOS).
 * Clase pura (sin Android) para poder probarla.
 */
class ScrollMomentum(
    private val decayPerMs: Double = 0.998,
    private val minStartVelocity: Double = 250.0, // px/s
    private val stopVelocity: Double = 20.0, // px/s
) {
    private var vx = 0.0
    private var vy = 0.0

    var isActive = false
        private set

    /** Empieza la inercia si la velocidad (px/s) es suficiente. Devuelve si arrancó. */
    fun start(velocityX: Double, velocityY: Double): Boolean {
        isActive = hypot(velocityX, velocityY) >= minStartVelocity
        if (isActive) {
            vx = velocityX
            vy = velocityY
        }
        return isActive
    }

    fun cancel() {
        isActive = false
        vx = 0.0
        vy = 0.0
    }

    /**
     * Avanza [dtMs] y devuelve el desplazamiento (px) de ese intervalo, o null si la inercia terminó.
     * El desplazamiento es la integral exacta de v·decay^t en el intervalo.
     */
    fun step(dtMs: Double): Pair<Double, Double>? {
        if (!isActive) return null
        val decay = decayPerMs.pow(dtMs)
        // ∫0^dt v·k^t dt = v·(k^dt − 1)/ln(k), con t en ms y v en px/ms.
        val factor = (decay - 1.0) / kotlin.math.ln(decayPerMs) / 1000.0
        val dx = vx * factor
        val dy = vy * factor
        vx *= decay
        vy *= decay
        if (abs(vx) < stopVelocity && abs(vy) < stopVelocity) isActive = false
        return dx to dy
    }
}
