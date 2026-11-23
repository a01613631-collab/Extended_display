import Foundation
import Network

/// Servidor TCP en el puerto 47800.
/// - Solo USB: escucha únicamente en la interfaz loopback (adb reverse llega por 127.0.0.1).
/// - Con Wi-Fi: escucha en todas las interfaces y se anuncia por Bonjour (`_tabdisplay._tcp`).
final class Server {
    var onConnection: ((NWConnection) -> Void)?
    /// nil = escuchando bien; texto = error para mostrar en el menú.
    var onStateChange: ((String?) -> Void)?

    private let queue: DispatchQueue
    private let port: UInt16
    private var listener: NWListener?
    private(set) var wifiEnabled = false

    init(queue: DispatchQueue, port: UInt16 = ProtocolConstants.defaultPort) {
        self.queue = queue
        self.port = port
    }

    func start(wifi: Bool) {
        stop()
        wifiEnabled = wifi

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        if !wifi {
            parameters.requiredInterfaceType = .loopback
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Log.net.error("No se pudo crear el listener: \(error.localizedDescription, privacy: .public)")
            onStateChange?("No se pudo abrir el puerto \(port): \(error.localizedDescription)")
            return
        }
        if wifi {
            // nil = nombre de la computadora (Ajustes → General → Compartir).
            listener.service = NWListener.Service(name: nil, type: ProtocolConstants.serviceType)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.net.info("Escuchando en el puerto \(self.port) (\(wifi ? "USB + Wi-Fi" : "solo USB", privacy: .public))")
                self.onStateChange?(nil)
            case .failed(let error):
                Log.net.error("Listener falló: \(error.localizedDescription, privacy: .public)")
                self.onStateChange?("El servidor falló: \(error.localizedDescription). ¿Hay otra copia de TabDisplay abierta?")
                // Reintento automático (p. ej. si el puerto estaba ocupado por una instancia anterior).
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.listener === listener else { return }
                    self.start(wifi: wifi)
                }
            case .waiting(let error):
                self.onStateChange?("Servidor en espera: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }
}
