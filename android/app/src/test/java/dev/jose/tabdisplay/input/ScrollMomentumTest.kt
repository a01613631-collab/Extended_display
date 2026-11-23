package dev.jose.tabdisplay.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ln

class ScrollMomentumTest {
    @Test
    fun slowFlingDoesNotStart() {
        val momentum = ScrollMomentum()
        assertFalse(momentum.start(100.0, 0.0))
        assertFalse(momentum.isActive)
    }

    @Test
    fun totalDistanceMatchesIntegral() {
        val momentum = ScrollMomentum(decayPerMs = 0.998, minStartVelocity = 1.0, stopVelocity = 0.001)
        assertTrue(momentum.start(2000.0, -1000.0))
        var totalX = 0.0
        var totalY = 0.0
        var steps = 0
        while (momentum.isActive && steps < 100_000) {
            val (dx, dy) = momentum.step(8.0)!!
            totalX += dx
            totalY += dy
            steps++
        }
        // Distancia total = v0 / −ln(k) (v en px/ms): 2 px/ms / 0.002002 ≈ 999 px.
        val expectedX = 2.0 / -ln(0.998)
        assertEquals(expectedX, totalX, 0.5)
        assertEquals(-expectedX / 2, totalY, 0.5)
    }

    @Test
    fun stepIsIndependentOfFrameRate() {
        val a = ScrollMomentum(minStartVelocity = 1.0)
        val b = ScrollMomentum(minStartVelocity = 1.0)
        a.start(3000.0, 0.0)
        b.start(3000.0, 0.0)
        var da = 0.0
        var db = 0.0
        repeat(10) { da += a.step(16.0)!!.first }
        repeat(20) { db += b.step(8.0)!!.first }
        assertEquals(da, db, 1e-6)
    }

    @Test
    fun cancelStops() {
        val momentum = ScrollMomentum()
        momentum.start(5000.0, 0.0)
        momentum.cancel()
        assertFalse(momentum.isActive)
        assertEquals(null, momentum.step(16.0))
    }
}
