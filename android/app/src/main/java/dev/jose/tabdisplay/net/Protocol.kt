package dev.jose.tabdisplay.net

import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.nio.ByteBuffer

// Implementación del protocolo descrito en docs/PROTOCOL.md. Todo big-endian (default de ByteBuffer).

object MsgType {
    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val CODEC_CONFIG = 0x03
    const val VIDEO_FRAME = 0x04
    const val TOUCH = 0x10
    const val SCROLL = 0x11
    const val KEYFRAME_REQUEST = 0x20
    const val PING = 0x30
    const val PONG = 0x31
    const val STATS = 0x40
    const val BYE = 0x7F
}

object ByeReason {
    const val NORMAL = 0
    const val PROTOCOL_ERROR = 1
    const val VERSION_MISMATCH = 2
    const val UNAUTHORIZED = 3
    const val REPLACED = 4
    const val SHUTTING_DOWN = 5
    const val RECONFIGURE = 6
}

object TouchAction {
    const val DOWN = 0
    const val MOVE = 1
    const val UP = 2
    const val CANCEL = 3
    const val HOVER_MOVE = 4
    const val HOVER_EXIT = 5
}

object ToolType {
    const val FINGER = 0
    const val STYLUS = 1
    const val ERASER = 2
}

object ScrollPhase {
    const val BEGAN = 0
    const val CHANGED = 1
    const val ENDED = 2
    const val MOMENTUM = 3
}

class ProtocolException(message: String) : IOException(message)

data class Header(val type: Int, val flags: Int, val length: Int, val timestampUs: Long) {
    val isKeyframe: Boolean get() = (flags and Protocol.FLAG_KEYFRAME) != 0
}

object Protocol {
    const val VERSION = 1
    const val DEFAULT_PORT = 47800
    const val HEADER_SIZE = 16
    const val MAX_PAYLOAD = 8 * 1024 * 1024
    const val FLAG_KEYFRAME = 0x01
    const val TOUCH_SIZE = 20
    const val SCROLL_SIZE = 9
    const val SERVICE_TYPE = "_tabdisplay._tcp"
    const val BUTTON_STYLUS_PRIMARY = 0x01

    /** Reloj monotónico de la tablet en microsegundos (ver PROTOCOL.md, "Relojes usados"). */
    fun nowUs(): Long = System.nanoTime() / 1000

    /** Mensaje completo (encabezado + payload) en un solo arreglo: se escribe con una sola llamada a write(). */
    fun encode(type: Int, timestampUs: Long, payload: ByteArray? = null, flags: Int = 0): ByteArray {
        val length = payload?.size ?: 0
        val buffer = ByteBuffer.allocate(HEADER_SIZE + length)
        buffer.put(type.toByte())
        buffer.put(flags.toByte())
        buffer.putShort(0)
        buffer.putInt(length)
        buffer.putLong(timestampUs)
        if (payload != null) buffer.put(payload)
        return buffer.array()
    }

    fun parseHeader(bytes: ByteArray): Header {
        val buffer = ByteBuffer.wrap(bytes, 0, HEADER_SIZE)
        val type = buffer.get().toInt() and 0xFF
        val flags = buffer.get().toInt() and 0xFF
        buffer.getShort() // reserved
        val length = buffer.getInt()
        val timestampUs = buffer.getLong()
        // Un u32 > 2^31 llega negativo como Int: también es inválido.
        if (length < 0 || length > MAX_PAYLOAD) throw ProtocolException("payload inválido: $length bytes")
        return Header(type, flags, length, timestampUs)
    }

    fun readHeader(input: DataInputStream, scratch: ByteArray): Header {
        input.readFully(scratch, 0, HEADER_SIZE)
        return parseHeader(scratch)
    }

    fun readPayload(input: DataInputStream, length: Int): ByteArray {
        val payload = ByteArray(length)
        input.readFully(payload)
        return payload
    }

    fun encodeTouch(
        action: Int,
        pointerId: Int,
        toolType: Int,
        buttons: Int,
        x: Float,
        y: Float,
        pressure: Float,
    ): ByteArray {
        val buffer = ByteBuffer.allocate(TOUCH_SIZE)
        buffer.put(action.toByte())
        buffer.put(pointerId.toByte())
        buffer.put(toolType.toByte())
        buffer.put(buttons.toByte())
        buffer.putFloat(x)
        buffer.putFloat(y)
        buffer.putFloat(pressure)
        buffer.putInt(0)
        return buffer.array()
    }

    fun encodeScroll(dx: Float, dy: Float, phase: Int): ByteArray {
        val buffer = ByteBuffer.allocate(SCROLL_SIZE)
        buffer.putFloat(dx)
        buffer.putFloat(dy)
        buffer.put(phase.toByte())
        return buffer.array()
    }

    fun encodeLong(value: Long): ByteArray = ByteBuffer.allocate(8).putLong(value).array()

    fun decodeLong(payload: ByteArray): Long {
        if (payload.size < 8) throw ProtocolException("se esperaban 8 bytes, llegaron ${payload.size}")
        return ByteBuffer.wrap(payload).getLong()
    }
}

data class CodecSupport(val mime: String, val lowLatency: Boolean, val max60: Boolean, val max120: Boolean)

data class Hello(
    val deviceName: String,
    val widthPx: Int,
    val heightPx: Int,
    val densityDpi: Int,
    val refreshRates: List<Int>,
    val codecs: List<CodecSupport>,
    val transport: String,
    val token: String?,
) {
    fun toJson(): ByteArray {
        val json = JSONObject()
        json.put("protocolVersion", Protocol.VERSION)
        json.put("deviceName", deviceName)
        json.put("widthPx", widthPx)
        json.put("heightPx", heightPx)
        json.put("densityDpi", densityDpi)
        json.put("refreshRates", JSONArray(refreshRates))
        val codecArray = JSONArray()
        for (codec in codecs) {
            codecArray.put(
                JSONObject()
                    .put("mime", codec.mime)
                    .put("lowLatency", codec.lowLatency)
                    .put("max60", codec.max60)
                    .put("max120", codec.max120),
            )
        }
        json.put("codecs", codecArray)
        json.put("transport", transport)
        json.put("token", token ?: JSONObject.NULL)
        return json.toString().toByteArray(Charsets.UTF_8)
    }
}

data class HelloAck(
    val protocolVersion: Int,
    val accepted: Boolean,
    val reason: String?,
    val codec: String,
    val streamWidthPx: Int,
    val streamHeightPx: Int,
    val fps: Int,
    val bitrate: Int,
    val pairingToken: String?,
    val macName: String?,
) {
    companion object {
        fun parse(payload: ByteArray): HelloAck {
            val json = try {
                JSONObject(String(payload, Charsets.UTF_8))
            } catch (e: Exception) {
                throw ProtocolException("HELLO_ACK no es JSON válido")
            }
            return HelloAck(
                protocolVersion = json.optInt("protocolVersion", 0),
                accepted = json.optBoolean("accepted", false),
                reason = json.optStringOrNull("reason"),
                codec = json.optString("codec", "video/avc"),
                streamWidthPx = json.optInt("streamWidthPx", 0),
                streamHeightPx = json.optInt("streamHeightPx", 0),
                fps = json.optInt("fps", 60),
                bitrate = json.optInt("bitrate", 0),
                pairingToken = json.optStringOrNull("pairingToken"),
                macName = json.optStringOrNull("macName"),
            )
        }

        private fun JSONObject.optStringOrNull(key: String): String? =
            if (has(key) && !isNull(key)) getString(key) else null
    }
}
