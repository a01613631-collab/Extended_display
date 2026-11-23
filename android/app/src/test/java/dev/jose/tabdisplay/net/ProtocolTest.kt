package dev.jose.tabdisplay.net

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream

/** Vectores de prueba de docs/PROTOCOL.md. La Mac tiene las mismas pruebas en XCTest. */
class ProtocolTest {
    private fun hex(s: String): ByteArray {
        val clean = s.replace(" ", "")
        return ByteArray(clean.length / 2) { clean.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    @Test
    fun keyframeRequestHeader() {
        val bytes = Protocol.encode(MsgType.KEYFRAME_REQUEST, 0x0102030405060708L)
        assertArrayEquals(hex("20 00 0000 00000000 0102030405060708"), bytes)
    }

    @Test
    fun touchVector() {
        val bytes = Protocol.encodeTouch(TouchAction.DOWN, 1, ToolType.STYLUS, 1, 0.5f, 0.25f, 1.0f)
        assertArrayEquals(hex("00 01 01 01 3F000000 3E800000 3F800000 00000000"), bytes)
    }

    @Test
    fun scrollVector() {
        val bytes = Protocol.encodeScroll(-2.5f, 10.0f, ScrollPhase.CHANGED)
        assertArrayEquals(hex("C0200000 41200000 01"), bytes)
    }

    @Test
    fun pongVector() {
        val bytes = Protocol.encode(MsgType.PONG, 1000, Protocol.encodeLong(999))
        assertArrayEquals(hex("31 00 0000 00000008 00000000000003E8 00000000000003E7"), bytes)
        val header = Protocol.parseHeader(bytes)
        assertEquals(MsgType.PONG, header.type)
        assertEquals(8, header.length)
        assertEquals(1000L, header.timestampUs)
        assertEquals(999L, Protocol.decodeLong(bytes.copyOfRange(16, 24)))
    }

    @Test
    fun keyframeFlag() {
        val header = Protocol.parseHeader(Protocol.encode(MsgType.VIDEO_FRAME, 5, ByteArray(3), flags = 1))
        assertTrue(header.isKeyframe)
        assertEquals(3, header.length)
        assertFalse(Protocol.parseHeader(Protocol.encode(MsgType.VIDEO_FRAME, 5, ByteArray(3))).isKeyframe)
    }

    @Test(expected = ProtocolException::class)
    fun rejectsOversizedPayload() {
        Protocol.parseHeader(hex("04 00 0000 00800001 0000000000000000"))
    }

    @Test(expected = ProtocolException::class)
    fun rejectsNegativeLength() {
        Protocol.parseHeader(hex("04 00 0000 FFFFFFFF 0000000000000000"))
    }

    @Test
    fun readsMessagesFromStream() {
        val stream = Protocol.encode(MsgType.PING, 7) + Protocol.encode(MsgType.BYE, 8, byteArrayOf(6))
        val input = DataInputStream(ByteArrayInputStream(stream))
        val scratch = ByteArray(Protocol.HEADER_SIZE)
        val ping = Protocol.readHeader(input, scratch)
        assertEquals(MsgType.PING, ping.type)
        assertEquals(0, ping.length)
        val bye = Protocol.readHeader(input, scratch)
        assertEquals(MsgType.BYE, bye.type)
        assertArrayEquals(byteArrayOf(6), Protocol.readPayload(input, bye.length))
    }

    @Test
    fun helloJson() {
        val hello = Hello(
            "Tab", 2800, 1752, 266, listOf(60, 120),
            listOf(CodecSupport("video/avc", true, true, false)), "usb", null,
        )
        val json = JSONObject(String(hello.toJson()))
        assertEquals(1, json.getInt("protocolVersion"))
        assertEquals(2800, json.getInt("widthPx"))
        assertEquals(120, json.getJSONArray("refreshRates").getInt(1))
        assertEquals("video/avc", json.getJSONArray("codecs").getJSONObject(0).getString("mime"))
        assertTrue(json.isNull("token"))
    }

    @Test
    fun helloAckJson() {
        val ack = HelloAck.parse(
            """{"protocolVersion":1,"accepted":true,"codec":"video/hevc","streamWidthPx":2800,
               "streamHeightPx":1752,"fps":120,"bitrate":30000000,"pairingToken":"abc","macName":"Mac"}""".toByteArray(),
        )
        assertTrue(ack.accepted)
        assertEquals("video/hevc", ack.codec)
        assertEquals(120, ack.fps)
        assertEquals("abc", ack.pairingToken)
        assertNull(ack.reason)

        val rejected = HelloAck.parse("""{"protocolVersion":1,"accepted":false,"reason":"token"}""".toByteArray())
        assertFalse(rejected.accepted)
        assertEquals("token", rejected.reason)
        assertNull(rejected.pairingToken)
    }

    @Test(expected = ProtocolException::class)
    fun helloAckRejectsGarbage() {
        HelloAck.parse("no json".toByteArray())
    }
}
