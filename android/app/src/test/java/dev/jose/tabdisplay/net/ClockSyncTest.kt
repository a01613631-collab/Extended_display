package dev.jose.tabdisplay.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClockSyncTest {
    @Test
    fun estimatesOffsetWithSymmetricDelay() {
        val clock = ClockSync()
        assertNull(clock.offsetUs)
        // La Mac va 1 000 000 µs adelantada; RTT de 4 ms, simétrico.
        clock.onPong(nowUs = 10_004_000, echoUs = 10_000_000, macUs = 11_002_000)
        assertEquals(1_000_000L, clock.offsetUs)
        assertEquals(4_000L, clock.rttUs)
        assertEquals(5_000L, clock.macToLocalUs(1_005_000))
    }

    @Test
    fun medianIgnoresOutliers() {
        val clock = ClockSync(window = 5)
        repeat(4) { i -> clock.onPong(1000L + i * 100 + 2, 1000L + i * 100, 50_001L + i * 100) }
        // Una muestra con mucho retraso de un solo lado.
        clock.onPong(2_000_000, 1_900_000, 1_950_000 + 49_000 + 40_000)
        assertEquals(49_000L, clock.offsetUs)
    }

    @Test
    fun keepsOnlyWindow() {
        val clock = ClockSync(window = 3)
        repeat(3) { clock.onPong(102, 100, 1_101) } // offset 1000
        repeat(3) { clock.onPong(102, 100, 2_101) } // offset 2000
        assertEquals(2_000L, clock.offsetUs)
    }

    @Test
    fun rejectsNegativeRtt() {
        val clock = ClockSync()
        clock.onPong(nowUs = 10, echoUs = 20, macUs = 0)
        assertNull(clock.offsetUs)
    }
}
