import CoreGraphics
import Foundation
import Network
import SystemConfiguration

enum Transport: String, Equatable {
    case usb
    case wifi

    var label: String { self == .usb ? "USB" : "Wi-Fi" }
}

struct StreamMetrics: Equatable {
    var fpsSent: Double = 0
    var mbpsSent: Double = 0
    var encodeMs: Double = 0
    var droppedFrames = 0
    var bitrate = 0
    var tablet: TabletStats?
}

/// Estado que ve la interfaz.
struct ServiceStatus: Equatable {
    enum Phase: Equatable {
        case waiting
        case starting
        case streaming
    }

    var phase: Phase = .waiting
    var transport: Transport?
    var deviceName: String?
    var codec: VideoCodec?
    var streamWidth = 0
    var streamHeight = 0
    var fps = 0
    /// nil = aún no se sabe; false = el códec no aceptó el modo de baja latencia (habrá más retraso).
    var encoderLowLatency: Bool?
    var metrics: StreamMetrics?
    var virtualDisplayActive = false
    var serverError: String?
    var sessionError: String?
    var recordingMessage: String?
    var isRecording = false
}

/// Núcleo de la app: servidor, sesión con la tablet, monitor virtual, captura y entrada.
/// Todo su estado vive en `queue`; la interfaz recibe `ServiceStatus` en la cola principal.
final class DisplayService {
    var onStatus: ((ServiceStatus) -> Void)?

    private let queue = DispatchQueue(label: "dev.jose.tabdisplay.service", qos: .userInteractive)
    private lazy var server = Server(queue: queue)
    private let virtualDisplay = VirtualDisplayManager()
    private let injector = InputInjector()
    private let macName: String

    private var settings: AppSettings
    private var pending: [UUID: ClientConnection] = [:]
    private var session: Session?
    private var graceWork: DispatchWorkItem?
    private var metricsTimer: DispatchSourceTimer?
    private var recorder: TestRecorder?
    private var status = ServiceStatus() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            DispatchQueue.main.async { [weak self] in self?.onStatus?(snapshot) }
        }
    }

    /// Una tablet conectada.
    private final class Session {
        let connection: ClientConnection
        let transport: Transport
        let hello: HelloMessage
        let codec: VideoCodec
        let width: Int
        let height: Int
        let fps: Int
        var bitrate: Int
        var displayID: CGDirectDisplayID = 0
        var pipeline: StreamPipeline?
        var gestures: GestureResolver?

        // Control de flujo (PROTOCOL.md, "Reglas de robustez").
        var waitingForKeyframe = true
        var keyframeRequested = true

        // Métricas del último segundo.
        var framesSent = 0
        var bytesSentAtLastTick: UInt64 = 0
        var encodeUsSum: UInt64 = 0
        var encodeCount = 0
        var droppedFrames = 0
        var congestionThisSecond = 0
        var tabletStats: TabletStats?

        // Ajuste de bitrate en Wi-Fi.
        var baselineRttMs: Double?
        var stableSeconds = 0

        init(connection: ClientConnection, transport: Transport, hello: HelloMessage,
             codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int) {
            self.connection = connection
            self.transport = transport
            self.hello = hello
            self.codec = codec
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
        macName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    // MARK: - API pública (cualquier hilo)

    func start() {
        queue.async { [self] in
            injector.stylusPressureEnabled = settings.stylusPressure
            server.onConnection = { [weak self] connection in self?.accept(connection) }
            server.onStateChange = { [weak self] error in self?.status.serverError = error }
            server.start(wifi: settings.wifiEnabled)
            startMetricsTimer()
        }
    }

    func update(settings newSettings: AppSettings) {
        queue.async { [self] in apply(newSettings) }
    }

    /// "Reconectar": la tablet reconecta de inmediato y se renegocia todo.
    func reconnect() {
        queue.async { [self] in
            if session != nil { endSession(bye: .reconfigure) }
        }
    }

    /// Invalida el emparejamiento Wi-Fi actual.
    func revokePairing() {
        queue.async { [self] in
            PairingTokenStore.regenerate()
            if session?.transport == .wifi { endSession(bye: .unauthorized) }
        }
    }

    /// Fase 1: graba `seconds` segundos del monitor (sin tablet) a ~/Desktop/test.h264.
    func recordTestFile(seconds: Int = 10) {
        queue.async { [self] in startRecording(seconds: seconds) }
    }

    /// Al salir de la app: avisa a la tablet y quita el monitor virtual.
    func shutdown() {
        queue.sync {
            if session != nil { endSession(bye: .shuttingDown) }
            server.stop()
            graceWork?.cancel()
            virtualDisplay.deactivate()
        }
        // Breve espera para que el BYE alcance a salir por el socket.
        Thread.sleep(forTimeInterval: 0.15)
    }

    // MARK: - Ajustes

    private func apply(_ newSettings: AppSettings) {
        let old = settings
        settings = newSettings
        injector.stylusPressureEnabled = newSettings.stylusPressure

        if old.wifiEnabled != newSettings.wifiEnabled {
            server.start(wifi: newSettings.wifiEnabled)
            if !newSettings.wifiEnabled, session?.transport == .wifi {
                endSession(bye: .shuttingDown)
            }
        }

        if let session {
            let needsRenegotiation = old.preset != newSettings.preset || old.mode != newSettings.mode
                || old.codec != newSettings.codec || old.highRefreshRate != newSettings.highRefreshRate
            if needsRenegotiation {
                Log.app.info("Ajustes cambiaron: se renegocia la sesión")
                endSession(bye: .reconfigure)
            } else if session.transport == .usb, old.usbBitrateMbps != newSettings.usbBitrateMbps {
                setBitrate(session, newSettings.usbBitrateMbps * 1_000_000)
            } else if session.transport == .wifi, old.wifiMaxBitrateMbps != newSettings.wifiMaxBitrateMbps {
                setBitrate(session, min(session.bitrate, newSettings.wifiMaxBitrateMbps * 1_000_000))
            }
        } else if old.mode != newSettings.mode, newSettings.mode == .mirror {
            graceWork?.cancel()
            virtualDisplay.deactivate()
            status.virtualDisplayActive = false
        }
    }

    // MARK: - Conexiones

    private func accept(_ nwConnection: NWConnection) {
        let client = ClientConnection(connection: nwConnection, queue: queue)
        Log.net.info("Conexión entrante de \(client.remoteDescription, privacy: .public) (\(client.isLoopback ? "USB" : "Wi-Fi", privacy: .public))")
        pending[client.id] = client
        client.onMessage = { [weak self, weak client] header, payload in
            guard let self, let client else { return }
            self.handleHandshake(client, header, payload)
        }
        client.onClose = { [weak self] closed, _ in
            self?.pending[closed.id] = nil
        }
        client.start()
    }

    private func handleHandshake(_ client: ClientConnection, _ header: MessageHeader, _ payload: Data) {
        guard header.type == MsgType.hello.rawValue else {
            // Antes del HELLO solo importa un BYE; lo demás (p. ej. un PING adelantado) se responde o ignora.
            switch MsgType(rawValue: header.type) {
            case .bye?:
                client.close(nil)
            case .ping?:
                var echo = Data()
                echo.appendBE(header.timestampUs)
                client.send(.pong, payload: echo)
            default:
                break
            }
            return
        }
        pending[client.id] = nil
        guard let hello = try? JSONDecoder().decode(HelloMessage.self, from: payload) else {
            Log.net.error("HELLO inválido")
            client.sendBye(.protocolError)
            return
        }
        let transport: Transport = client.isLoopback ? .usb : .wifi

        switch negotiate(hello, transport: transport) {
        case .failure(let rejection):
            Log.net.warning("Tablet rechazada: \(rejection.message, privacy: .public)")
            client.sendJSON(.helloAck, HelloAckMessage(accepted: false, reason: rejection.message))
            client.sendBye(rejection.bye)
        case .success(let params):
            if session != nil {
                Log.net.info("Nueva tablet válida: reemplaza a la conexión anterior")
                endSession(bye: .replaced)
            }
            startSession(client, hello: hello, params: params, transport: transport)
        }
    }

    private struct StreamParams {
        let codec: VideoCodec
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
    }

    private struct Rejection: Error {
        let message: String
        let bye: ByeReason
    }

    private func negotiate(_ hello: HelloMessage, transport: Transport) -> Result<StreamParams, Rejection> {
        guard hello.protocolVersion == ProtocolConstants.version else {
            return .failure(Rejection(
                message: "Versión de protocolo \(hello.protocolVersion) incompatible (la Mac usa \(ProtocolConstants.version)). Actualiza ambas apps.",
                bye: .versionMismatch))
        }
        if transport == .wifi {
            guard settings.wifiEnabled else {
                return .failure(Rejection(message: "El modo Wi-Fi está desactivado en la Mac.", bye: .unauthorized))
            }
            guard PairingTokenStore.matches(hello.token) else {
                return .failure(Rejection(message: "Tablet no emparejada. Conéctala una vez por cable.", bye: .unauthorized))
            }
        }
        guard hello.widthPx >= 320, hello.heightPx >= 200 else {
            return .failure(Rejection(message: "Tamaño de pantalla inválido.", bye: .protocolError))
        }

        let codecs = hello.codecs ?? [CodecCapability(mime: CodecMime.h264, lowLatency: nil, max60: true, max120: nil)]
        func capability(_ codec: VideoCodec) -> CodecCapability? { codecs.first { $0.mime == codec.mime } }
        var codec: VideoCodec = settings.codec
        if capability(codec) == nil || capability(codec)?.max60 == false {
            codec = capability(.h264) != nil ? .h264 : .hevc
        }
        guard capability(codec) != nil else {
            return .failure(Rejection(message: "La tablet no tiene decodificador H.264 ni HEVC por hardware.", bye: .protocolError))
        }

        // Tamaño del stream = panel de la tablet (horizontal), par y dentro de los límites del códec.
        let maxSide = codec == .h264 ? 4096 : 8192
        var width = max(hello.widthPx, hello.heightPx)
        var height = min(hello.widthPx, hello.heightPx)
        if width > maxSide {
            height = height * maxSide / width
            width = maxSide
        }
        width &= ~1
        height &= ~1

        let supports120 = (hello.refreshRates ?? []).contains { $0 >= 120 } && capability(codec)?.max120 == true
        let fps = settings.highRefreshRate && supports120 ? 120 : 60
        let bitrate = transport == .usb
            ? settings.usbBitrateMbps * 1_000_000
            : settings.wifiMaxBitrateMbps * 1_000_000
        return .success(StreamParams(codec: codec, width: width, height: height, fps: fps, bitrate: bitrate))
    }

    // MARK: - Sesión

    private func startSession(_ client: ClientConnection, hello: HelloMessage, params: StreamParams, transport: Transport) {
        graceWork?.cancel()
        graceWork = nil
        if recorder != nil { stopRecording(reason: "La tablet se conectó; grabación detenida.") }

        let session = Session(connection: client, transport: transport, hello: hello, codec: params.codec,
                              width: params.width, height: params.height, fps: params.fps, bitrate: params.bitrate)
        self.session = session
        client.onMessage = { [weak self, weak session] header, payload in
            guard let self, let session else { return }
            self.handleMessage(session, header, payload)
        }
        client.onClose = { [weak self] closed, _ in
            guard let self, let session = self.session, session.connection === closed else { return }
            self.endSession(bye: nil)
        }
        client.onVideoFrameSent = { [weak self, weak session] in
            guard let self, let session else { return }
            self.videoFrameSent(session)
        }

        client.sendJSON(.helloAck, HelloAckMessage(
            accepted: true,
            codec: params.codec.mime,
            streamWidthPx: params.width,
            streamHeightPx: params.height,
            fps: params.fps,
            bitrate: params.bitrate,
            pairingToken: transport == .usb ? PairingTokenStore.current() : nil,
            macName: macName))

        Log.app.info("Sesión \(transport.label, privacy: .public) con \(hello.deviceName ?? "tablet", privacy: .public): \(params.codec.rawValue, privacy: .public) \(params.width)×\(params.height) @\(params.fps)")
        status.phase = .starting
        status.transport = transport
        status.deviceName = hello.deviceName
        status.codec = params.codec
        status.streamWidth = params.width
        status.streamHeight = params.height
        status.fps = params.fps
        status.sessionError = nil
        status.metrics = nil
        status.encoderLowLatency = nil

        startPipeline(session)
    }

    /// Prepara el monitor y arranca captura + codificador. Si falla (p. ej. sin permiso de
    /// Grabación de pantalla) reintenta cada 3 s mientras la tablet siga conectada.
    private func startPipeline(_ session: Session) {
        guard self.session === session else { return }
        do {
            let displayID = try prepareCaptureTarget(fps: session.fps)
            session.displayID = displayID
            status.virtualDisplayActive = virtualDisplay.isActive

            let gestures = GestureResolver(
                schedule: { [weak self] delay, work in
                    self?.queue.asyncAfter(deadline: .now() + delay, execute: work)
                },
                emit: { [weak self] actions in self?.injector.perform(actions) })
            session.gestures = gestures

            let pipeline = try StreamPipeline(displayID: displayID, width: session.width, height: session.height,
                                              fps: session.fps, codec: session.codec, bitrate: session.bitrate)
            pipeline.onFrame = { [weak self, weak session] frame in
                self?.queue.async {
                    guard let self, let session else { return }
                    self.send(frame, in: session)
                }
            }
            pipeline.onStop = { [weak self, weak session] error in
                self?.queue.async {
                    guard let self, let session, self.session === session else { return }
                    self.pipelineFailed(session, error)
                }
            }
            session.pipeline = pipeline
            session.waitingForKeyframe = true
            session.keyframeRequested = true

            Task { [weak self, weak session] in
                do {
                    try await pipeline.start()
                    self?.queue.async {
                        guard let self, let session, self.session === session else {
                            pipeline.stop()
                            return
                        }
                        self.status.phase = .streaming
                        self.status.sessionError = nil
                        self.status.encoderLowLatency = pipeline.encoder.lowLatencyMode
                    }
                } catch {
                    self?.queue.async {
                        guard let self, let session, self.session === session else { return }
                        self.pipelineFailed(session, error)
                    }
                }
            }
        } catch {
            pipelineFailed(session, error)
        }
    }

    private func pipelineFailed(_ session: Session, _ error: Error) {
        Log.app.error("No se pudo transmitir: \(error.localizedDescription, privacy: .public)")
        session.pipeline?.stop()
        session.pipeline = nil
        status.phase = .starting
        status.sessionError = Self.describe(error)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
            guard let self, let session, self.session === session, session.pipeline == nil else { return }
            self.startPipeline(session)
        }
    }

    private func prepareCaptureTarget(fps: Int) throws -> CGDirectDisplayID {
        if settings.mode == .mirror {
            virtualDisplay.deactivate()
            return CGMainDisplayID()
        }
        return try virtualDisplay.activate(
            widthPoints: settings.preset.widthPoints,
            heightPoints: settings.preset.heightPoints,
            refreshRate: fps,
            allPresets: DisplayPreset.all.map { ($0.widthPoints, $0.heightPoints) })
    }

    private func endSession(bye: ByeReason?) {
        guard let session else { return }
        self.session = nil
        session.pipeline?.stop()
        session.pipeline = nil
        session.gestures?.reset()
        if let bye { session.connection.sendBye(bye) } else { session.connection.close(nil) }
        Log.app.info("Sesión terminada")

        status.phase = .waiting
        status.transport = nil
        status.deviceName = nil
        status.metrics = nil
        status.sessionError = nil
        scheduleVirtualDisplayTeardown()
    }

    private func scheduleVirtualDisplayTeardown() {
        graceWork?.cancel()
        guard virtualDisplay.isActive else {
            status.virtualDisplayActive = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == nil, self.recorder == nil else { return }
            self.virtualDisplay.deactivate()
            self.status.virtualDisplayActive = false
        }
        graceWork = work
        queue.asyncAfter(deadline: .now() + .seconds(max(0, settings.gracePeriodSeconds)), execute: work)
    }

    // MARK: - Video

    private func send(_ frame: EncodedFrame, in session: Session) {
        guard self.session === session, !session.connection.isClosed else { return }
        let connection = session.connection
        session.encodeUsSum += frame.encodeDurationUs
        session.encodeCount += 1

        if frame.isKeyframe {
            session.waitingForKeyframe = false
            session.keyframeRequested = false
            if let parameterSets = frame.parameterSets {
                connection.send(.codecConfig, timestampUs: frame.timestampUs, payload: parameterSets)
            }
            connection.send(.videoFrame, flags: ProtocolConstants.flagKeyframe, timestampUs: frame.timestampUs, payload: frame.data)
            session.framesSent += 1
            return
        }
        if session.waitingForKeyframe {
            session.droppedFrames += 1
            return
        }
        if connection.pendingVideoFrames > 2 {
            // Socket atrasado: se descartan cuadros P hasta poder mandar un keyframe nuevo.
            session.droppedFrames += 1
            session.congestionThisSecond += 1
            session.waitingForKeyframe = true
            session.keyframeRequested = false
            return
        }
        connection.send(.videoFrame, timestampUs: frame.timestampUs, payload: frame.data)
        session.framesSent += 1
    }

    private func videoFrameSent(_ session: Session) {
        guard session.waitingForKeyframe, !session.keyframeRequested,
              session.connection.pendingVideoFrames <= 1 else { return }
        session.keyframeRequested = true
        session.pipeline?.requestKeyframe()
    }

    // MARK: - Mensajes de la tablet

    private func handleMessage(_ session: Session, _ header: MessageHeader, _ payload: Data) {
        guard let type = MsgType(rawValue: header.type) else { return } // tipo desconocido: se ignora
        switch type {
        case .touch:
            guard let touch = try? TouchEvent(parsing: payload) else { return protocolError(session) }
            session.gestures?.handle(touch, at: map(session, x: touch.x, y: touch.y))
        case .scroll:
            guard let scroll = try? ScrollEvent(parsing: payload) else { return protocolError(session) }
            let scale = pointsPerStreamPixel(session)
            session.gestures?.handleScroll(dx: Double(scroll.dx) * scale, dy: Double(scroll.dy) * scale, phase: scroll.phase)
        case .keyframeRequest:
            session.pipeline?.requestKeyframe()
        case .ping:
            var echo = Data()
            echo.appendBE(header.timestampUs)
            session.connection.send(.pong, payload: echo)
        case .stats:
            if let stats = try? JSONDecoder().decode(TabletStats.self, from: payload) {
                session.tabletStats = stats
            }
        case .bye:
            Log.net.info("La tablet cerró la sesión (motivo \(payload.first ?? 0))")
            endSession(bye: nil)
        case .pong, .hello, .helloAck, .codecConfig, .videoFrame:
            break
        }
    }

    private func protocolError(_ session: Session) {
        Log.net.error("Mensaje mal formado de la tablet")
        endSession(bye: .protocolError)
    }

    /// Rectángulo de la pantalla capturada dentro del stream (normalizado). En "Extender" ocupa todo;
    /// en "Duplicar" la pantalla principal puede tener otra proporción y quedar con barras.
    private func contentRect(_ session: Session, bounds: CGRect) -> CGRect {
        let streamAspect = Double(session.width) / Double(session.height)
        let displayAspect = Double(bounds.width) / Double(max(bounds.height, 1))
        if displayAspect > streamAspect + 0.001 {
            let h = streamAspect / displayAspect
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        } else if displayAspect < streamAspect - 0.001 {
            let w = displayAspect / streamAspect
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func map(_ session: Session, x: Float, y: Float) -> CGPoint {
        let bounds = CGDisplayBounds(session.displayID)
        let content = contentRect(session, bounds: bounds)
        let nx = min(max((CGFloat(x) - content.minX) / content.width, 0), 1)
        let ny = min(max((CGFloat(y) - content.minY) / content.height, 0), 1)
        // El borde derecho/inferior exacto ya pertenece a la pantalla vecina.
        return CGPoint(x: bounds.minX + min(nx * bounds.width, bounds.width - 1),
                       y: bounds.minY + min(ny * bounds.height, bounds.height - 1))
    }

    private func pointsPerStreamPixel(_ session: Session) -> Double {
        let bounds = CGDisplayBounds(session.displayID)
        let content = contentRect(session, bounds: bounds)
        return Double(bounds.width) / (Double(session.width) * Double(content.width))
    }

    // MARK: - Métricas y bitrate adaptativo (Wi-Fi)

    private func startMetricsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.metricsTick() }
        timer.resume()
        metricsTimer = timer
    }

    private func metricsTick() {
        guard let session else { return }
        let bytes = session.connection.bytesSent
        session.droppedFrames += session.pipeline?.takeSkippedFrames() ?? 0
        var metrics = StreamMetrics()
        metrics.fpsSent = Double(session.framesSent)
        metrics.mbpsSent = Double(bytes &- session.bytesSentAtLastTick) * 8 / 1_000_000
        metrics.encodeMs = session.encodeCount > 0 ? Double(session.encodeUsSum) / Double(session.encodeCount) / 1000 : 0
        metrics.droppedFrames = session.droppedFrames
        metrics.bitrate = session.bitrate
        metrics.tablet = session.tabletStats
        status.metrics = metrics

        if session.transport == .wifi { adaptWifiBitrate(session) }

        session.framesSent = 0
        session.bytesSentAtLastTick = bytes
        session.encodeUsSum = 0
        session.encodeCount = 0
        session.congestionThisSecond = 0
    }

    /// Wi-Fi: baja un 15 % si el socket se atrasa o el RTT se dispara mucho; sube un 10 % cada 2 s
    /// tras 3 s estables. Suave a propósito: el RTT en Wi-Fi tiene picos normales que no son congestión.
    private func adaptWifiBitrate(_ session: Session) {
        let maxBitrate = settings.wifiMaxBitrateMbps * 1_000_000
        let minBitrate = 8_000_000
        var congested = session.congestionThisSecond > 0
        if let rtt = session.tabletStats?.rttMs {
            let baseline = min(session.baselineRttMs ?? rtt, rtt)
            // La línea base sube muy despacio para olvidar mínimos viejos.
            session.baselineRttMs = baseline + 0.05
            if rtt > max(baseline * 3, baseline + 50) { congested = true }
        }
        if congested {
            session.stableSeconds = 0
            let lowered = max(minBitrate, session.bitrate * 85 / 100)
            if lowered != session.bitrate {
                Log.net.info("Wi-Fi congestionado: bitrate \(lowered / 1_000_000) Mbps")
                setBitrate(session, lowered)
            }
        } else {
            session.stableSeconds += 1
            if session.stableSeconds >= 3, session.bitrate < maxBitrate {
                session.stableSeconds = 1
                setBitrate(session, min(maxBitrate, session.bitrate * 110 / 100))
            }
        }
    }

    private func setBitrate(_ session: Session, _ bitrate: Int) {
        session.bitrate = bitrate
        session.pipeline?.setBitrate(bitrate)
    }

    // MARK: - Grabación de prueba (Fase 1)

    private final class TestRecorder {
        let pipeline: StreamPipeline
        let file: FileHandle
        let url: URL
        var frames = 0
        var keyframes = 0
        var bytes = 0
        var encodeUsSum: UInt64 = 0
        let startUs = HostClock.nowUs()

        init(pipeline: StreamPipeline, file: FileHandle, url: URL) {
            self.pipeline = pipeline
            self.file = file
            self.url = url
        }
    }

    private func startRecording(seconds: Int) {
        guard session == nil else {
            status.recordingMessage = "Desconecta la tablet para grabar la prueba."
            return
        }
        guard recorder == nil else { return }
        do {
            graceWork?.cancel()
            let displayID = try prepareCaptureTarget(fps: 60)
            status.virtualDisplayActive = virtualDisplay.isActive
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let url = desktop.appendingPathComponent("test.h264")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: 0)

            let pipeline = try StreamPipeline(displayID: displayID, width: 2800, height: 1752, fps: 60,
                                              codec: .h264, bitrate: settings.usbBitrateMbps * 1_000_000)
            let recorder = TestRecorder(pipeline: pipeline, file: file, url: url)
            self.recorder = recorder
            pipeline.onFrame = { [weak self, weak recorder] frame in
                self?.queue.async {
                    guard let recorder, self?.recorder === recorder else { return }
                    if let parameterSets = frame.parameterSets { recorder.file.write(parameterSets) }
                    recorder.file.write(frame.data)
                    recorder.frames += 1
                    recorder.keyframes += frame.isKeyframe ? 1 : 0
                    recorder.bytes += frame.data.count
                    recorder.encodeUsSum += frame.encodeDurationUs
                }
            }
            status.isRecording = true
            status.recordingMessage = "Grabando \(seconds) s… mueve una ventana en el monitor \(settings.mode == .extend ? "virtual" : "principal")."
            Task { [weak self] in
                do {
                    try await pipeline.start()
                } catch {
                    self?.queue.async { self?.stopRecording(reason: Self.describe(error)) }
                }
            }
            queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self, weak recorder] in
                guard let self, let recorder, self.recorder === recorder else { return }
                self.stopRecording(reason: nil)
            }
        } catch {
            status.recordingMessage = Self.describe(error)
        }
    }

    private func stopRecording(reason: String?) {
        guard let recorder else { return }
        self.recorder = nil
        recorder.pipeline.stop()
        try? recorder.file.close()
        status.isRecording = false
        if let reason {
            status.recordingMessage = reason
        } else {
            let seconds = Double(HostClock.nowUs() &- recorder.startUs) / 1_000_000
            let fps = Double(recorder.frames) / max(seconds, 0.001)
            let encodeMs = recorder.frames > 0 ? Double(recorder.encodeUsSum) / Double(recorder.frames) / 1000 : 0
            let mbps = Double(recorder.bytes) * 8 / max(seconds, 0.001) / 1_000_000
            let message = String(format: "test.h264 en el Escritorio: %d cuadros (%.1f fps), %.1f Mbps, codificación promedio %.1f ms. Ábrelo con: ffplay ~/Desktop/test.h264",
                                 recorder.frames, fps, mbps, encodeMs)
            Log.app.info("\(message, privacy: .public)")
            status.recordingMessage = message
        }
        if session == nil { scheduleVirtualDisplayTeardown() }
    }

    // MARK: - Utilidades

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        // SCStreamError.userDeclined (-3801): falta el permiso de Grabación de pantalla.
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3801 {
            return "Falta el permiso de Grabación de pantalla."
        }
        return error.localizedDescription
    }
}
