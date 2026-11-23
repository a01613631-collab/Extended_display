import Foundation
import Security

/// Tamaños del monitor virtual en PUNTOS (HiDPI 2×). El stream siempre sale al tamaño en píxeles
/// de la tablet; los presets con más puntos se reescalan al capturar.
struct DisplayPreset: Codable, Hashable, Identifiable {
    let widthPoints: Int
    let heightPoints: Int

    var id: String { "\(widthPoints)x\(heightPoints)" }

    var label: String {
        switch self {
        case .native: return "\(widthPoints) × \(heightPoints) (nítido, 2×)"
        default: return "\(widthPoints) × \(heightPoints) (más espacio)"
        }
    }

    static let native = DisplayPreset(widthPoints: 1400, heightPoints: 876)
    static let medium = DisplayPreset(widthPoints: 1600, heightPoints: 1000)
    static let large = DisplayPreset(widthPoints: 1680, heightPoints: 1050)
    static let all: [DisplayPreset] = [.native, .medium, .large]
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    /// Monitor virtual adicional (escritorio extendido).
    case extend
    /// Duplica la pantalla principal (sin monitor virtual).
    case mirror

    var id: String { rawValue }
    var label: String { self == .extend ? "Extender" : "Duplicar" }
}

/// Ajustes persistentes (UserDefaults, JSON). Los campos que falten al leer toman su valor por defecto.
struct AppSettings: Codable, Equatable {
    var preset: DisplayPreset = .native
    var mode: DisplayMode = .extend
    var codec: VideoCodec = .h264
    /// 120 Hz (experimental): solo si la tablet y el códec lo soportan.
    var highRefreshRate = false
    var usbBitrateMbps = 30
    /// En Wi-Fi el bitrate se ajusta solo, sin pasar de este máximo.
    var wifiMaxBitrateMbps = 30
    var wifiEnabled = false
    /// Segundos que el monitor virtual sigue vivo tras desconectar (para reconexiones rápidas).
    var gracePeriodSeconds = 10
    /// Vacío = buscar adb en las rutas habituales.
    var adbPath = ""
    var autoLaunchTabletApp = true
    var stylusPressure = false

    static let usbBitrateOptions = [15, 20, 30, 40, 50]
    static let wifiBitrateOptions = [10, 15, 20, 30, 40]
    static let graceOptions = [0, 5, 10, 30, 60]

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? c.decodeIfPresent(DisplayPreset.self, forKey: .preset)) ?? defaults.preset
        mode = (try? c.decodeIfPresent(DisplayMode.self, forKey: .mode)) ?? defaults.mode
        codec = (try? c.decodeIfPresent(VideoCodec.self, forKey: .codec)) ?? defaults.codec
        highRefreshRate = (try? c.decodeIfPresent(Bool.self, forKey: .highRefreshRate)) ?? defaults.highRefreshRate
        usbBitrateMbps = (try? c.decodeIfPresent(Int.self, forKey: .usbBitrateMbps)) ?? defaults.usbBitrateMbps
        wifiMaxBitrateMbps = (try? c.decodeIfPresent(Int.self, forKey: .wifiMaxBitrateMbps)) ?? defaults.wifiMaxBitrateMbps
        wifiEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .wifiEnabled)) ?? defaults.wifiEnabled
        gracePeriodSeconds = (try? c.decodeIfPresent(Int.self, forKey: .gracePeriodSeconds)) ?? defaults.gracePeriodSeconds
        adbPath = (try? c.decodeIfPresent(String.self, forKey: .adbPath)) ?? defaults.adbPath
        autoLaunchTabletApp = (try? c.decodeIfPresent(Bool.self, forKey: .autoLaunchTabletApp)) ?? defaults.autoLaunchTabletApp
        stylusPressure = (try? c.decodeIfPresent(Bool.self, forKey: .stylusPressure)) ?? defaults.stylusPressure
        if !DisplayPreset.all.contains(preset) { preset = .native }
    }

    private static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Token de emparejamiento Wi-Fi: 32 bytes aleatorios en base64. Se entrega a la tablet solo por USB.
enum PairingTokenStore {
    private static let key = "pairingToken.v1"

    static func current() -> String {
        if let token = UserDefaults.standard.string(forKey: key), !token.isEmpty { return token }
        return regenerate()
    }

    /// Genera uno nuevo: invalida el emparejamiento de cualquier tablet.
    @discardableResult
    static func regenerate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes falló")
        let token = Data(bytes).base64EncodedString()
        UserDefaults.standard.set(token, forKey: key)
        return token
    }

    /// Comparación en tiempo constante.
    static func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let expected = Array(current().utf8)
        let given = Array(candidate.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<expected.count {
            difference |= expected[i] ^ given[i]
        }
        return difference == 0
    }
}
