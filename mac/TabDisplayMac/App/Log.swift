import CoreMedia
import Foundation
import os

/// Loggers por área. Ver en Console.app filtrando por el subsistema `dev.jose.tabdisplay.mac`,
/// o en terminal: `log stream --predicate 'subsystem == "dev.jose.tabdisplay.mac"'`.
enum Log {
    private static let subsystem = "dev.jose.tabdisplay.mac"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let encoder = Logger(subsystem: subsystem, category: "encoder")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let device = Logger(subsystem: subsystem, category: "device")
}

/// Reloj del protocolo en la Mac: el reloj de host de CoreMedia, el mismo de los
/// `CMSampleBuffer` de ScreenCaptureKit (PROTOCOL.md, "Relojes usados").
enum HostClock {
    static func nowUs() -> UInt64 {
        microseconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    static func microseconds(_ time: CMTime) -> UInt64 {
        guard time.isValid else { return nowUs() }
        let value = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero).value
        return UInt64(max(0, value))
    }
}
