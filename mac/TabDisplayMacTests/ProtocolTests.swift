import XCTest

/// Vectores de docs/PROTOCOL.md (los mismos que prueba Android en ProtocolTest.kt).
final class ProtocolTests: XCTestCase {
    private func hex(_ string: String) -> Data {
        let clean = string.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            data.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    func testKeyframeRequestHeader() {
        let data = MessageHeader.message(.keyframeRequest, timestampUs: 0x0102030405060708)
        XCTAssertEqual(data, hex("20 00 0000 00000000 0102030405060708"))
    }

    func testTouchVector() throws {
        let touch = TouchEvent(action: .down, pointerId: 1, toolType: .stylus, buttons: 1, x: 0.5, y: 0.25, pressure: 1.0)
        let expected = hex("00 01 01 01 3F000000 3E800000 3F800000 00000000")
        XCTAssertEqual(touch.encoded(), expected)
        let parsed = try TouchEvent(parsing: expected)
        XCTAssertEqual(parsed, touch)
        XCTAssertTrue(parsed.isSideButtonPressed)
    }

    func testScrollVector() throws {
        let expected = hex("C0200000 41200000 01")
        let scroll = try ScrollEvent(parsing: expected)
        XCTAssertEqual(scroll, ScrollEvent(dx: -2.5, dy: 10, phase: .changed))
        XCTAssertEqual(scroll.encoded(), expected)
    }

    func testPongVector() throws {
        var echo = Data()
        echo.appendBE(UInt64(999))
        let data = MessageHeader.message(.pong, timestampUs: 1000, payload: echo)
        XCTAssertEqual(data, hex("31 00 0000 00000008 00000000000003E8 00000000000003E7"))
        let header = try MessageHeader(parsing: data)
        XCTAssertEqual(header.type, MsgType.pong.rawValue)
        XCTAssertEqual(header.length, 8)
        XCTAssertEqual(header.timestampUs, 1000)
        XCTAssertEqual(data.dropFirst(16).be(UInt64.self, at: 0), 999)
    }

    func testRejectsOversizedPayload() {
        XCTAssertThrowsError(try MessageHeader(parsing: hex("04 00 0000 00800001 0000000000000000")))
        XCTAssertNoThrow(try MessageHeader(parsing: hex("04 00 0000 00800000 0000000000000000")))
    }

    func testKeyframeFlag() throws {
        let data = MessageHeader.message(.videoFrame, flags: ProtocolConstants.flagKeyframe, timestampUs: 5, payload: Data([1, 2, 3]))
        let header = try MessageHeader(parsing: data)
        XCTAssertTrue(header.isKeyframe)
        XCTAssertEqual(header.length, 3)
    }

    func testRejectsInvalidTouchAction() {
        XCTAssertThrowsError(try TouchEvent(parsing: hex("09 01 01 01 3F000000 3E800000 3F800000 00000000")))
    }

    func testHelloDecoding() throws {
        let json = """
        {"protocolVersion":1,"deviceName":"Galaxy Tab S8+","widthPx":2800,"heightPx":1752,"densityDpi":266,
         "refreshRates":[60,120],"codecs":[{"mime":"video/avc","lowLatency":true,"max60":true,"max120":false}],
         "transport":"usb","token":null}
        """
        let hello = try JSONDecoder().decode(HelloMessage.self, from: Data(json.utf8))
        XCTAssertEqual(hello.widthPx, 2800)
        XCTAssertEqual(hello.codecs?.first?.mime, CodecMime.h264)
        XCTAssertNil(hello.token)
    }

    func testHelloAckOmitsNilFields() throws {
        let ack = HelloAckMessage(accepted: false, reason: "no")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as? [String: Any]
        XCTAssertEqual(object?["accepted"] as? Bool, false)
        XCTAssertEqual(object?["protocolVersion"] as? Int, 1)
        XCTAssertNil(object?["pairingToken"])
    }
}
