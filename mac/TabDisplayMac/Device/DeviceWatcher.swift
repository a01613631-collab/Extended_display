import Foundation

/// Detecta la tablet por USB con `adb devices` cada 2 s. Al verla: `adb reverse` del puerto y
/// lanza la app de Android. Todo corre en su propia cola (los procesos pueden tardar).
final class DeviceWatcher {
    struct Device: Equatable, Identifiable {
        let serial: String
        /// "device", "unauthorized", "offline"…
        let state: String
        var model: String?
        var reverseActive: Bool

        var id: String { serial }
        var isReady: Bool { state == "device" }
    }

    struct Snapshot: Equatable {
        var adbPath: String?
        var devices: [Device] = []
        var error: String?
    }

    /// Se llama en la cola principal cuando cambia algo.
    var onUpdate: ((Snapshot) -> Void)?

    var customAdbPath = ""
    var autoLaunchTabletApp = true

    private let queue = DispatchQueue(label: "dev.jose.tabdisplay.adb", qos: .utility)
    private let port: UInt16
    private let activity = "dev.jose.tabdisplay/.MainActivity"
    private var timer: DispatchSourceTimer?
    /// Seriales a los que ya se les hizo `adb reverse` (se limpia cuando desaparecen).
    private var configured = Set<String>()
    private var models: [String: String] = [:]
    private var tickCount = 0
    private var lastSnapshot = Snapshot()

    init(port: UInt16 = ProtocolConstants.defaultPort) {
        self.port = port
    }

    func start() {
        queue.async { [self] in
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Fuerza rehacer `adb reverse` y relanzar la app en el siguiente ciclo ("Reconectar").
    func reconfigureAll() {
        queue.async { [self] in
            configured.removeAll()
            tick()
        }
    }

    func setOptions(customAdbPath: String, autoLaunch: Bool) {
        queue.async { [self] in
            self.customAdbPath = customAdbPath
            self.autoLaunchTabletApp = autoLaunch
        }
    }

    // MARK: - Ciclo

    private func tick() {
        tickCount += 1
        var snapshot = Snapshot()
        guard let adb = resolveAdb() else {
            snapshot.error = "No se encontró adb. Instálalo con: brew install android-platform-tools"
            publish(snapshot)
            return
        }
        snapshot.adbPath = adb

        guard let output = run(adb, ["devices"]) else {
            snapshot.error = "adb no respondió"
            publish(snapshot)
            return
        }

        var devices = Self.parseDevices(output.stdout)
        let present = Set(devices.map(\.serial))
        configured.formIntersection(present)
        models = models.filter { present.contains($0.key) }

        // Cada ~10 s se verifica que el reverse siga activo (adb lo pierde si se reinicia su servidor).
        if tickCount % 5 == 0 {
            for serial in configured {
                if let list = run(adb, ["-s", serial, "reverse", "--list"]), !list.stdout.contains("tcp:\(port)") {
                    Log.device.info("\(serial, privacy: .public): reverse perdido, se rehace")
                    configured.remove(serial)
                }
            }
        }

        for index in devices.indices where devices[index].isReady {
            let serial = devices[index].serial
            if models[serial] == nil, let result = run(adb, ["-s", serial, "shell", "getprop", "ro.product.model"]) {
                models[serial] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            devices[index].model = models[serial]
            if !configured.contains(serial) {
                configure(adb: adb, serial: serial)
            }
            devices[index].reverseActive = configured.contains(serial)
        }

        if devices.contains(where: { $0.state == "unauthorized" }) {
            snapshot.error = "Acepta la huella RSA en la tablet (\"¿Permitir depuración USB?\")."
        }
        snapshot.devices = devices
        publish(snapshot)
    }

    private func configure(adb: String, serial: String) {
        guard let reverse = run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]), reverse.status == 0 else {
            Log.device.error("\(serial, privacy: .public): adb reverse falló")
            return
        }
        Log.device.info("\(serial, privacy: .public): adb reverse tcp:\(self.port) listo")
        configured.insert(serial)
        if autoLaunchTabletApp {
            let launch = run(adb, ["-s", serial, "shell", "am", "start", "-n", activity])
            if let launch, launch.stdout.contains("Error") || launch.stderr.contains("Error") {
                Log.device.warning("\(serial, privacy: .public): no se pudo abrir la app (¿está instalada?): \(launch.stdout + launch.stderr, privacy: .public)")
            }
        }
    }

    private func publish(_ snapshot: Snapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }

    // MARK: - adb

    static func parseDevices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            return Device(serial: parts[0], state: parts[1], model: nil, reverseActive: false)
        }
    }

    private func resolveAdb() -> String? {
        let fileManager = FileManager.default
        if !customAdbPath.isEmpty {
            return fileManager.isExecutableFile(atPath: customAdbPath) ? customAdbPath : nil
        }
        var candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.insert(sdk + "/platform-tools/adb", at: 0)
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Ejecuta un proceso con tiempo límite (adb puede colgarse si el dispositivo está a medio conectar).
    /// La salida va a archivos temporales y no a pipes: cuando `adb` arranca su servidor en segundo
    /// plano, el servidor podría heredar el pipe y `readDataToEndOfFile` no terminaría nunca.
    private func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> ProcessResult? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let outURL = tempDir.appendingPathComponent("tabdisplay-adb-\(UUID().uuidString).out")
        let errURL = tempDir.appendingPathComponent("tabdisplay-adb-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else { return nil }
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        do {
            try process.run()
        } catch {
            Log.device.error("No se pudo ejecutar \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()

        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: out, as: UTF8.self),
                             stderr: String(decoding: err, as: UTF8.self))
    }
}
