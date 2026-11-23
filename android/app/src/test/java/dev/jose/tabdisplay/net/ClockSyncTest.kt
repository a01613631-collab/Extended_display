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
    fun usesSampleWithLowestRtt() {
        val clock = ClockSync(window = 10)
        // Una sola muestra limpia (RTT 2 µs, offset 49 000)…
        clock.onPong(1002, 1000, 50_001)
        // …y muchas con el PONG retrasado 400 ms detrás del video (RTT grande, offset sesgado).
        repeat(8) { i ->
            val echo = 2_000_000L + i * 1_000_000
            clock.onPong(echo + 400_000, echo, echo + 49_000 + 400_000)
        }
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
