import Foundation

/// ค่าตั้งของ proxy ที่ persist ลง UserDefaults
struct ProxySettings: Codable, Equatable {
    var port: UInt16
    var vhosts: [ProxyVHost]
    var autoStartOnLaunch: Bool

    static let `default` = ProxySettings(
        port: 8888,
        vhosts: [],
        autoStartOnLaunch: false
    )
}

/// load/save ProxySettings ผ่าน UserDefaults (key เดียวเป็น JSON)
enum ProxySettingsStore {
    private static let key = "mhost.proxy.settings.v1"

    static func load() -> ProxySettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ProxySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: ProxySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
