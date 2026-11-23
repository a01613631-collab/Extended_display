import Foundation

// Implementación del protocolo de docs/PROTOCOL.md. Todos los enteros son big-endian.
// Este archivo no depende de nada más de la app (lo compilan también las pruebas).

enum ProtocolConstants {
    static let version = 1
    static let defaultPort: UInt16 = 47800
    static let headerSize = 16
    static let maxPayload: UInt32 = 8 * 1024 * 1024
    static let serviceType = "_tabdisplay._tcp"
    static let flagKeyframe: UInt8 = 0x01
}

enum MsgType: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case codecConfig = 0x03
    case videoFrame = 0x04
    case touch = 0x10
    case scroll = 0x11
    case keyframeRequest = 0x20
    case ping = 0x30
    case pong = 0x31
    case stats = 0x40
    case bye = 0x7F
}

enum ByeReason: UInt8 {
    case normal = 0
    case protocolError = 1
    case versionMismatch = 2
    case unauthorized = 3
    case replaced = 4
    case shuttingDown = 5
    case reconfigure = 6
}

enum ProtocolError: Error, Equatable {
    case payloadTooLarge(UInt32)
    case malformed(String)
}

struct MessageHeader: Equatable {
    var type: UInt8
    var flags: UInt8
    var length: UInt32
    var timestampUs: UInt64

    init(type: UInt8, flags: UInt8 = 0, length: UInt32, timestampUs: UInt64) {
        self.type = type
        self.flags = flags
        self.length = length
        self.timestampUs = timestampUs
    }

    init(parsing data: Data) throws {
        guard data.count >= ProtocolConstants.headerSize else { throw ProtocolError.malformed("encabezado corto") }
        type = data.be(UInt8.self, at: 0)
        flags = data.be(UInt8.self, at: 1)
        length = data.be(UInt32.self, at: 4)
        timestampUs = data.be(UInt64.self, at: 8)
        guard length <= ProtocolConstants.maxPayload else { throw ProtocolError.payloadTooLarge(length) }
    }

    var isKeyframe: Bool { flags & ProtocolConstants.flagKeyframe != 0 }

    func encoded() -> Data {
        var data = Data(capacity: ProtocolConstants.headerSize)
        data.appendBE(type)
        data.appendBE(flags)
        data.appendBE(UInt16(0))
        data.appendBE(length)
        data.appendBE(timestampUs)
        return data
    }

    /// Mensaje completo (encabezado + payload), listo para mandarse en un solo write.
    static func message(_ type: MsgType, flags: UInt8 = 0, timestampUs: UInt64, payload: Data = Data()) -> Data {
        var data = MessageHeader(type: type.rawValue, flags: flags, length: UInt32(payload.count),
                                 timestampUs: timestampUs).encoded()
        data.append(payload)
        return data
    }
}

enum TouchAction: UInt8 {
    case down = 0, move = 1, up = 2, cancel = 3, hoverMove = 4, hoverExit = 5
}

enum ToolType: UInt8 {
    case finger = 0, stylus = 1, eraser = 2
}

struct TouchEvent: Equatable {
    static let size = 20
    static let buttonStylusPrimary: UInt8 = 0x01

    var action: TouchAction
    var pointerId: UInt8
    var toolType: ToolType
    var buttons: UInt8
    var x: Float
    var y: Float
    var pressure: Float

    var isSideButtonPressed: Bool { buttons & Self.buttonStylusPrimary != 0 }

    init(action: TouchAction, pointerId: UInt8, toolType: ToolType, buttons: UInt8, x: Float, y: Float, pressure: Float) {
        self.action = action
        self.pointerId = pointerId
        self.toolType = toolType
        self.buttons = buttons
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    init(parsing data: Data) throws {
        guard data.count >= Self.size else { throw ProtocolError.malformed("TOUCH corto") }
        guard let action = TouchAction(rawValue: data.be(UInt8.self, at: 0)) else {
            throw ProtocolError.malformed("TOUCH action inválida")
        }
        // Un toolType desconocido (versión futura) se trata como dedo.
        self.action = action
        pointerId = data.be(UInt8.self, at: 1)
        toolType = ToolType(rawValue: data.be(UInt8.self, at: 2)) ?? .finger
        buttons = data.be(UInt8.self, at: 3)
        x = Float(bitPattern: data.be(UInt32.self, at: 4))
        y = Float(bitPattern: data.be(UInt32.self, at: 8))
        pressure = Float(bitPattern: data.be(UInt32.self, at: 12))
        guard x.isFinite, y.isFinite, pressure.isFinite else { throw ProtocolError.malformed("TOUCH no finito") }
    }

    func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.appendBE(action.rawValue)
        data.appendBE(pointerId)
        data.appendBE(toolType.rawValue)
        data.appendBE(buttons)
        data.appendBE(x.bitPattern)
        data.appendBE(y.bitPattern)
        data.appendBE(pressure.bitPattern)
        data.appendBE(UInt32(0))
        return data
    }
}

enum ScrollPhase: UInt8 {
    case began = 0, changed = 1, ended = 2, momentum = 3
}

struct ScrollEvent: Equatable {
    static let size = 9

    /// Desplazamiento en píxeles del stream (PROTOCOL.md, SCROLL).
    var dx: Float
    var dy: Float
    var phase: ScrollPhase

    init(dx: Float, dy: Float, phase: ScrollPhase) {
        self.dx = dx
        self.dy = dy
        self.phase = phase
    }

    init(parsing data: Data) throws {
        guard data.count >= Self.size else { throw ProtocolError.malformed("SCROLL corto") }
        dx = Float(bitPattern: data.be(UInt32.self, at: 0))
        dy = Float(bitPattern: data.be(UInt32.self, at: 4))
        guard let phase = ScrollPhase(rawValue: data.be(UInt8.self, at: 8)) else {
            throw ProtocolError.malformed("SCROLL phase inválida")
        }
        guard dx.isFinite, dy.isFinite else { throw ProtocolError.malformed("SCROLL no finito") }
        self.phase = phase
    }

    func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.appendBE(dx.bitPattern)
        data.appendBE(dy.bitPattern)
        data.appendBE(phase.rawValue)
        return data
    }
}

// MARK: - Mensajes JSON

struct CodecCapability: Codable, Equatable {
    var mime: String
    var lowLatency: Bool?
    var max60: Bool?
    var max120: Bool?
}

struct HelloMessage: Codable, Equatable {
    var protocolVersion: Int
    var deviceName: String?
    var widthPx: Int
    var heightPx: Int
    var densityDpi: Int?
    var refreshRates: [Int]?
    var codecs: [CodecCapability]?
    var transport: String?
    var token: String?
}

struct HelloAckMessage: Codable, Equatable {
    var protocolVersion: Int = ProtocolConstants.version
    var accepted: Bool
    var reason: String?
    var codec: String?
    var streamWidthPx: Int?
    var streamHeightPx: Int?
    var fps: Int?
    var bitrate: Int?
    var pairingToken: String?
    var macName: String?
}

struct TabletStats: Codable, Equatable {
    var fpsReceived: Double?
    var fpsRendered: Double?
    var mbps: Double?
    var rttMs: Double?
    var latencyMs: Double?
    var droppedFrames: Int?
    var decoder: String?
}

enum CodecMime {
    static let h264 = "video/avc"
    static let hevc = "video/hevc"
}

// MARK: - Big-endian

extension Data {
    /// Lee un entero big-endian en `offset` (relativo al inicio de los datos).
    func be<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value = (value << 8) | T(self[startIndex + offset + i])
        }
        return value
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
