import CoreGraphics
import Foundation

/// Crea y administra el monitor virtual con `CGVirtualDisplay` (API privada).
///
/// Es el ÚNICO archivo que toca la API privada. Si una actualización de macOS la rompe,
/// solo hay que arreglar este archivo y el bridging header.
final class VirtualDisplayManager {
    enum DisplayError: LocalizedError {
        case apiUnavailable
        case applyFailed
        case noDisplayID
        case modeNotFound(String)

        var errorDescription: String? {
            switch self {
            case .apiUnavailable:
                return "CGVirtualDisplay no está disponible en esta versión de macOS."
            case .applyFailed:
                return "macOS rechazó la configuración del monitor virtual."
            case .noDisplayID:
                return "El monitor virtual no obtuvo un identificador."
            case .modeNotFound(let mode):
                return "No se encontró el modo HiDPI \(mode) en el monitor virtual."
            }
        }
    }

    /// Tamaño físico de la Tab S8+ (para que macOS calcule bien la densidad).
    private static let sizeInMillimeters = CGSize(width: 267, height: 167)
    /// IDs fijos: macOS recuerda la posición del monitor en Ajustes → Pantallas.
    private static let vendorID: UInt32 = 0x7464 // "td"
    private static let productID: UInt32 = 0x5338 // "S8"
    private static let serialNumber: UInt32 = 0x0001

    /// Comprueba en tiempo de ejecución que las clases y selectores existan.
    static var isAvailable: Bool {
        guard let display = NSClassFromString("CGVirtualDisplay"),
              NSClassFromString("CGVirtualDisplayDescriptor") != nil,
              let settings = NSClassFromString("CGVirtualDisplaySettings"),
              let mode = NSClassFromString("CGVirtualDisplayMode")
        else { return false }
        return display.instancesRespond(to: NSSelectorFromString("initWithDescriptor:"))
            && display.instancesRespond(to: NSSelectorFromString("applySettings:"))
            && display.instancesRespond(to: NSSelectorFromString("displayID"))
            && settings.instancesRespond(to: NSSelectorFromString("setModes:"))
            && settings.instancesRespond(to: NSSelectorFromString("setHiDPI:"))
            && mode.instancesRespond(to: NSSelectorFromString("initWithWidth:height:refreshRate:"))
    }

    private var display: CGVirtualDisplay?
    /// Cómo interpreta macOS los modos registrados (se descubre la primera vez).
    private var modesArePixels = false
    private(set) var currentMode: (widthPoints: Int, heightPoints: Int, refreshRate: Int)?

    var displayID: CGDirectDisplayID? {
        guard let display, display.displayID != 0 else { return nil }
        return display.displayID
    }

    var isActive: Bool { display != nil }

    /// Crea el monitor (si no existe) y aplica el modo HiDPI `widthPoints × heightPoints` @ `refreshRate`.
    /// `allPresets` se registran todos para poder cambiar de preset sin recrear el monitor.
    @discardableResult
    func activate(widthPoints: Int, heightPoints: Int, refreshRate: Int,
                  allPresets: [(Int, Int)]) throws -> CGDirectDisplayID {
        guard Self.isAvailable else { throw DisplayError.apiUnavailable }

        if display == nil {
            let maxWidth = max(widthPoints, allPresets.map { $0.0 }.max() ?? 0)
            let maxHeight = max(heightPoints, allPresets.map { $0.1 }.max() ?? 0)
            display = try createDisplay(maxPixelsWide: UInt32(maxWidth * 2), maxPixelsHigh: UInt32(maxHeight * 2))
            modesArePixels = false
            currentMode = nil
            do {
                try applyModes(allPresets: allPresets, first: (widthPoints, heightPoints))
            } catch {
                display = nil
                throw error
            }
        }
        guard let displayID else { throw DisplayError.noDisplayID }

        if let current = currentMode, current.widthPoints == widthPoints,
           current.heightPoints == heightPoints, current.refreshRate == refreshRate {
            return displayID
        }
        do {
            try selectMode(widthPoints: widthPoints, heightPoints: heightPoints, refreshRate: refreshRate,
                           allPresets: allPresets)
        } catch {
            // Un monitor sin el modo correcto se vería mal en la tablet: mejor no dejarlo.
            deactivate()
            throw error
        }
        currentMode = (widthPoints: widthPoints, heightPoints: heightPoints, refreshRate: refreshRate)
        return displayID
    }

    /// Destruye el monitor: macOS lo quita de la configuración de pantallas.
    func deactivate() {
        guard display != nil else { return }
        Log.display.info("Destruyendo monitor virtual")
        display = nil
        currentMode = nil
    }

    // MARK: - Privado

    private func createDisplay(maxPixelsWide: UInt32, maxPixelsHigh: UInt32) throws -> CGVirtualDisplay {
        let descriptor = CGVirtualDisplayDescriptor()
        if descriptor.responds(to: NSSelectorFromString("setDispatchQueue:")) {
            descriptor.setDispatchQueue(DispatchQueue.main)
        } else {
            descriptor.queue = DispatchQueue.main
        }
        descriptor.name = "Tab S8+"
        descriptor.maxPixelsWide = maxPixelsWide
        descriptor.maxPixelsHigh = maxPixelsHigh
        descriptor.sizeInMillimeters = Self.sizeInMillimeters
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = Self.serialNumber
        descriptor.terminationHandler = { _, _ in
            Log.display.warning("macOS terminó el monitor virtual")
        }
        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { throw DisplayError.noDisplayID }
        Log.display.info("Monitor virtual creado, displayID=\(display.displayID)")
        return display
    }

    /// Registra todos los presets a 60 y 120 Hz. El preset elegido va primero (macOS lo usa por defecto).
    private func applyModes(allPresets: [(Int, Int)], first: (Int, Int)) throws {
        guard let display else { return }
        let ordered = [first] + allPresets.filter { $0.0 != first.0 || $0.1 != first.1 }
        var modes: [CGVirtualDisplayMode] = []
        for rate in [60.0, 120.0] {
            for (w, h) in ordered {
                let scale = modesArePixels ? 2 : 1
                modes.append(CGVirtualDisplayMode(width: UInt(w * scale), height: UInt(h * scale), refreshRate: rate))
            }
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = modes
        guard display.apply(settings) else { throw DisplayError.applyFailed }
    }

    /// Busca el CGDisplayMode HiDPI (puntos = w, píxeles = 2w) y lo activa.
    ///
    /// No está documentado si `CGVirtualDisplayMode` se interpreta en puntos o en píxeles cuando
    /// hiDPI = 1. Se prueba primero en puntos; si no aparece el modo 2×, se re-registran los modos
    /// en píxeles. El resultado queda en el log (Console.app, subsistema dev.jose.tabdisplay.mac).
    private func selectMode(widthPoints: Int, heightPoints: Int, refreshRate: Int,
                            allPresets: [(Int, Int)]) throws {
        guard let displayID else { throw DisplayError.noDisplayID }
        var candidate = findMode(displayID, widthPoints, heightPoints, refreshRate)
        if candidate == nil && !modesArePixels {
            Log.display.info("Sin modo 2× con modos en puntos; se prueba registrándolos en píxeles")
            modesArePixels = true
            try applyModes(allPresets: allPresets, first: (widthPoints, heightPoints))
            candidate = findMode(displayID, widthPoints, heightPoints, refreshRate)
        }
        guard let mode = candidate else {
            logModes(displayID)
            throw DisplayError.modeNotFound("\(widthPoints)×\(heightPoints)@\(refreshRate)")
        }
        let result = CGDisplaySetDisplayMode(displayID, mode, nil)
        if result != .success {
            Log.display.error("CGDisplaySetDisplayMode falló: \(result.rawValue)")
        }
        Log.display.info("Modo activo: \(mode.width)×\(mode.height) pt, \(mode.pixelWidth)×\(mode.pixelHeight) px @\(mode.refreshRate) Hz (modos en \(self.modesArePixels ? "píxeles" : "puntos", privacy: .public))")
    }

    private func findMode(_ displayID: CGDirectDisplayID, _ w: Int, _ h: Int, _ rate: Int) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
        let hiDPI = modes.filter { $0.width == w && $0.height == h && $0.pixelWidth == w * 2 && $0.pixelHeight == h * 2 }
        // Tasa exacta si existe; si no, la más cercana (algunos modos virtuales reportan 0 Hz).
        return hiDPI.first { Int($0.refreshRate.rounded()) == rate }
            ?? hiDPI.min { abs($0.refreshRate - Double(rate)) < abs($1.refreshRate - Double(rate)) }
    }

    private func logModes(_ displayID: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        for mode in modes {
            Log.display.info("  modo: \(mode.width)×\(mode.height) pt, \(mode.pixelWidth)×\(mode.pixelHeight) px @\(mode.refreshRate)")
        }
    }
}
