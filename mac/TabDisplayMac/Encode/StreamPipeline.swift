import CoreGraphics
import CoreVideo
import Foundation

/// Captura + codificación de una pantalla. Todo el trabajo con el codificador ocurre en la cola
/// de captura, así `encode` nunca se llama en paralelo.
final class StreamPipeline {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps: Int
    let encoder: VideoEncoder

    /// Cuadros codificados (en un hilo de VideoToolbox).
    var onFrame: ((EncodedFrame) -> Void)? {
        didSet { encoder.onFrame = onFrame }
    }
    var onStop: ((Error) -> Void)?

    private let capture = CaptureEngine()
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureUs: UInt64 = 0
    private var lastEncodeUs: UInt64 = 0
    private var refreshesSinceCapture = 0
    private var refreshTimer: DispatchSourceTimer?
    private var stopped = false
    /// Cuadro capturado que espera a que el codificador se desocupe (solo el más reciente).
    private var pendingCapture: (CVPixelBuffer, UInt64)?
    private let counterLock = NSLock()
    private var skipped = 0

    /// Máximo de cuadros dentro del codificador. Más que esto sería una fila: latencia pura.
    private static let maxFramesInFlight = 2

    /// Re-codificaciones del último cuadro cuando la pantalla queda quieta: con control de tasa de
    /// baja latencia el primer cuadro tras un cambio grande sale borroso, y repetirlo lo afina.
    private static let refreshDelayUs: UInt64 = 250_000
    private static let maxRefreshes = 2

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, codec: VideoCodec, bitrate: Int) throws {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        encoder = try VideoEncoder(codec: codec, width: width, height: height, fps: fps, bitrate: bitrate)
        encoder.onEncodeComplete = { [weak self] in
            guard let self else { return }
            self.capture.queue.async { self.encodePendingIfPossible() }
        }
    }

    /// Cuadros capturados que se saltaron porque el codificador iba atrasado (desde la última lectura).
    func takeSkippedFrames() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        let value = skipped
        skipped = 0
        return value
    }

    func start() async throws {
        capture.onFrame = { [weak self] pixelBuffer, timestampUs in
            self?.handleCapture(pixelBuffer, timestampUs)
        }
        capture.onStop = { [weak self] error in
            self?.onStop?(error)
        }
        try await capture.start(displayID: displayID, width: width, height: height, fps: fps)

        let timer = DispatchSource.makeTimerSource(queue: capture.queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refreshIfIdle() }
        timer.resume()
        capture.queue.async { [weak self] in
            guard let self else {
                timer.cancel()
                return
            }
            if self.stopped { timer.cancel() } else { self.refreshTimer = timer }
        }
    }

    func stop() {
        capture.stop()
        capture.queue.async { [self] in
            stopped = true
            refreshTimer?.cancel()
            refreshTimer = nil
            lastPixelBuffer = nil
            pendingCapture = nil
            encoder.onFrame = nil
            encoder.onEncodeComplete = nil
            encoder.invalidate()
        }
    }

    /// Fuerza un keyframe ya: re-codifica el último cuadro (si la pantalla está quieta no
    /// llegaría ningún cuadro nuevo de ScreenCaptureKit).
    func requestKeyframe() {
        capture.queue.async { [self] in
            guard !stopped else { return }
            encoder.requestKeyframe()
            if let pixelBuffer = lastPixelBuffer {
                encode(pixelBuffer, timestampUs: HostClock.nowUs())
            }
        }
    }

    func setBitrate(_ bitrate: Int) {
        capture.queue.async { [self] in
            guard !stopped else { return }
            encoder.setBitrate(bitrate)
        }
    }

    // MARK: - Cola de captura

    private func handleCapture(_ pixelBuffer: CVPixelBuffer, _ timestampUs: UInt64) {
        guard !stopped else { return }
        lastPixelBuffer = pixelBuffer
        lastCaptureUs = HostClock.nowUs()
        refreshesSinceCapture = 0
        // Si el codificador va atrasado no se le hace fila: se guarda solo el cuadro más nuevo
        // y se codifica en cuanto salga uno (el que estaba esperando se descarta).
        if encoder.framesInFlight >= Self.maxFramesInFlight {
            if pendingCapture != nil { countSkipped() }
            pendingCapture = (pixelBuffer, timestampUs)
            return
        }
        pendingCapture = nil
        encode(pixelBuffer, timestampUs: timestampUs)
    }

    private func encodePendingIfPossible() {
        guard !stopped, let pending = pendingCapture,
              encoder.framesInFlight < Self.maxFramesInFlight else { return }
        pendingCapture = nil
        encode(pending.0, timestampUs: pending.1)
    }

    private func countSkipped() {
        counterLock.lock()
        skipped += 1
        counterLock.unlock()
    }

    private func refreshIfIdle() {
        guard !stopped, pendingCapture == nil, let pixelBuffer = lastPixelBuffer,
              refreshesSinceCapture < Self.maxRefreshes, encoder.framesInFlight == 0 else { return }
        let now = HostClock.nowUs()
        guard now &- lastCaptureUs >= Self.refreshDelayUs, now &- lastEncodeUs >= Self.refreshDelayUs else { return }
        refreshesSinceCapture += 1
        encode(pixelBuffer, timestampUs: now)
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, timestampUs: UInt64) {
        lastEncodeUs = HostClock.nowUs()
        encoder.encode(pixelBuffer, timestampUs: timestampUs)
    }
}
