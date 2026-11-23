import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captura una pantalla con ScreenCaptureKit en NV12 (420v), al tamaño en píxeles del stream.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: LocalizedError {
        case displayNotFound(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                return "ScreenCaptureKit no encuentra la pantalla \(id). ¿Falta el permiso de Grabación de pantalla?"
            }
        }
    }

    /// Cola donde llegan los cuadros; el codificador también se usa solo desde aquí.
    let queue = DispatchQueue(label: "dev.jose.tabdisplay.capture", qos: .userInteractive)

    /// (pixelBuffer, momento de captura en µs del reloj de host). Se llama en `queue`.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let display = try await findDisplay(displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // 420v evita conversiones: es lo que consume directamente el codificador por hardware.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // 4 en lugar de 3: se retiene el último buffer para poder re-codificarlo como keyframe.
        config.queueDepth = 4
        config.showsCursor = true
        config.capturesAudio = false
        config.preservesAspectRatio = true
        config.backgroundColor = CGColor.black

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.capture.info("Captura iniciada: pantalla \(displayID), \(width)×\(height) @\(fps)")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                Log.capture.info("stopCapture: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// La pantalla virtual tarda un momento en aparecer en SCShareableContent tras crearse.
    private func findDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                if attempt > 0 { Log.capture.info("Pantalla encontrada tras \(attempt) reintentos") }
                return display
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw CaptureError.displayNotFound(displayID)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Solo cuadros completos: .idle significa "sin cambios" y no trae imagen nueva.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame?(pixelBuffer, HostClock.microseconds(sampleBuffer.presentationTimeStamp))
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("La captura se detuvo: \(error.localizedDescription, privacy: .public)")
        self.stream = nil
        onStop?(error)
    }
}
