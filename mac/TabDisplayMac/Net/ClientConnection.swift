import Foundation
import Network

/// Una conexión TCP con la tablet: framing de lectura, envío y conteo de cuadros pendientes.
/// Todo corre en `queue` (la cola serial del servicio).
final class ClientConnection {
    let connection: NWConnection
    let id = UUID()
    /// Loopback = llegó por `adb reverse` (USB). Se decide por la dirección remota, no por lo que diga la tablet.
    let isLoopback: Bool
    let remoteDescription: String

    var onMessage: ((MessageHeader, Data) -> Void)?
    var onClose: ((ClientConnection, Error?) -> Void)?
    /// Se llama cada vez que un VIDEO_FRAME termina de entregarse al socket.
    var onVideoFrameSent: (() -> Void)?

    /// VIDEO_FRAME entregados a Network.framework que aún no pasan al socket.
    private(set) var pendingVideoFrames = 0
    private(set) var bytesSent: UInt64 = 0
    private(set) var isClosed = false

    private let queue: DispatchQueue
    private var lastReceiveUs = HostClock.nowUs()
    private var keepaliveTimer: DispatchSourceTimer?
    private static let receiveTimeoutUs: UInt64 = 5_000_000

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        var loopback = false
        var description = "\(connection.endpoint)"
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address):
                loopback = address.isLoopback
            case .ipv6(let address):
                loopback = address.isLoopback || (address.asIPv4?.isLoopback ?? false)
            case .name(let name, _):
                loopback = name == "localhost"
            @unknown default:
                loopback = false
            }
            description = "\(host)"
        }
        isLoopback = loopback
        remoteDescription = description
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.close(error)
            case .cancelled:
                self.close(nil)
            case .waiting(let error):
                // Una conexión entrante no debería quedar esperando: se trata como fallo.
                self.close(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHeader()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if HostClock.nowUs() &- self.lastReceiveUs > Self.receiveTimeoutUs {
                Log.net.warning("\(self.remoteDescription, privacy: .public): 5 s sin datos, se cierra")
                self.close(nil)
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: - Lectura

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: ProtocolConstants.headerSize,
                           maximumLength: ProtocolConstants.headerSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error {
                self.close(error)
                return
            }
            guard let data, data.count == ProtocolConstants.headerSize else {
                if !isComplete { self.protocolError("encabezado incompleto") } else { self.close(nil) }
                return
            }
            self.lastReceiveUs = HostClock.nowUs()
            let header: MessageHeader
            do {
                header = try MessageHeader(parsing: data)
            } catch {
                self.protocolError("\(error)")
                return
            }
            if header.length == 0 {
                self.deliver(header, Data())
                self.receiveHeader()
            } else {
                self.receivePayload(header)
            }
        }
    }

    private func receivePayload(_ header: MessageHeader) {
        let length = Int(header.length)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !self.isClosed else { return }
            if let error {
                self.close(error)
                return
            }
            guard let data, data.count == length else {
                self.close(nil)
                return
            }
            self.lastReceiveUs = HostClock.nowUs()
            self.deliver(header, data)
            self.receiveHeader()
        }
    }

    private func deliver(_ header: MessageHeader, _ payload: Data) {
        guard !isClosed else { return }
        onMessage?(header, payload)
    }

    private func protocolError(_ detail: String) {
        Log.net.error("\(self.remoteDescription, privacy: .public): error de protocolo: \(detail, privacy: .public)")
        sendBye(.protocolError)
    }

    // MARK: - Escritura

    func send(_ type: MsgType, flags: UInt8 = 0, timestampUs: UInt64 = HostClock.nowUs(), payload: Data = Data()) {
        guard !isClosed else { return }
        let message = MessageHeader.message(type, flags: flags, timestampUs: timestampUs, payload: payload)
        let isVideo = type == .videoFrame
        if isVideo { pendingVideoFrames += 1 }
        bytesSent += UInt64(message.count)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if isVideo {
                self.pendingVideoFrames -= 1
                self.onVideoFrameSent?()
            }
            if let error { self.close(error) }
        })
    }

    func sendJSON<T: Encodable>(_ type: MsgType, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(type, payload: data)
    }

    /// Manda BYE y cierra cuando el mensaje sale (o de inmediato si ya está cerrada).
    func sendBye(_ reason: ByeReason) {
        guard !isClosed else { return }
        Log.net.info("\(self.remoteDescription, privacy: .public): BYE \(reason.rawValue)")
        let message = MessageHeader.message(.bye, timestampUs: HostClock.nowUs(), payload: Data([reason.rawValue]))
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            self?.close(nil)
        })
        // Por si el envío nunca completa (socket atascado).
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close(nil) }
    }

    func close(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let error {
            Log.net.info("\(self.remoteDescription, privacy: .public): conexión cerrada: \(error.localizedDescription, privacy: .public)")
        } else {
            Log.net.info("\(self.remoteDescription, privacy: .public): conexión cerrada")
        }
        let handler = onClose
        onClose = nil
        onMessage = nil
        onVideoFrameSent = nil
        handler?(self, error)
    }
}
