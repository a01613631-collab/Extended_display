import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

/// Estado de la interfaz. Vive en el hilo principal y delega el trabajo a DisplayService/DeviceWatcher.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            service.update(settings: settings)
            deviceWatcher.setOptions(customAdbPath: settings.adbPath, autoLaunch: settings.autoLaunchTabletApp)
        }
    }
    @Published private(set) var status = ServiceStatus()
    @Published private(set) var adb = DeviceWatcher.Snapshot()
    @Published private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?
    let virtualDisplayAvailable = VirtualDisplayManager.isAvailable

    private let service: DisplayService
    private let deviceWatcher = DeviceWatcher()
    private var permissionTimer: Timer?

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        service = DisplayService(settings: settings)

        // Las pruebas unitarias no deben abrir puertos ni crear monitores.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        service.onStatus = { [weak self] status in self?.status = status }
        deviceWatcher.onUpdate = { [weak self] snapshot in self?.adb = snapshot }
        deviceWatcher.setOptions(customAdbPath: settings.adbPath, autoLaunch: settings.autoLaunchTabletApp)
        service.start()
        deviceWatcher.start()

        if !virtualDisplayAvailable {
            Log.app.error("CGVirtualDisplay no disponible: solo funcionará el modo Duplicar")
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deviceWatcher.stop()
                self?.service.shutdown()
            }
        }
    }

    // MARK: - Estado derivado

    var menuBarSymbol: String {
        if !problems.isEmpty && status.phase != .streaming { return "exclamationmark.triangle" }
        switch status.phase {
        case .streaming: return "rectangle.on.rectangle"
        case .starting: return "rectangle.dashed"
        case .waiting: return "rectangle"
        }
    }

    /// Problemas que impiden funcionar, en el orden en que conviene resolverlos.
    var problems: [String] {
        var list: [String] = []
        if !virtualDisplayAvailable && settings.mode == .extend {
            list.append("Esta versión de macOS no expone CGVirtualDisplay: usa el modo Duplicar o revisa si hay una actualización de TabDisplay.")
        }
        if !hasScreenRecording { list.append("Falta el permiso de Grabación de pantalla.") }
        if !hasAccessibility { list.append("Falta el permiso de Accesibilidad (necesario para tocar y usar el S Pen).") }
        if let error = status.serverError { list.append(error) }
        if let error = adb.error { list.append(error) }
        return list
    }

    // MARK: - Acciones

    func refreshPermissions() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func reconnect() {
        service.reconnect()
        deviceWatcher.reconfigureAll()
    }

    func recordTest() {
        service.recordTestFile(seconds: 10)
    }

    func revokePairing() {
        service.revokePairing()
    }

    func openDisplaySettings() {
        openSettings("x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
