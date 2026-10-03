import Foundation
import Security

/// Non-secret settings, shared with the engine via ~/.config/sd2immich/config.json
/// (written with 0600 permissions). The API key is NOT stored here; see `Keychain`.
struct AppSettings: Codable, Equatable {
    var server: String = ""
    var albumFormat: String = "%Y-%m-%d"
    var videos: Bool = true
    var rawOnly: Bool = false
    var relayHost: String = ""
    var relayDir: String = ".cache/sd2immich"
    var relayMinMB: Int = 300

    enum CodingKeys: String, CodingKey {
        case server, videos
        case albumFormat = "album_format"
        case rawOnly = "raw_only"
        case relayHost = "relay_host"
        case relayDir = "relay_dir"
        case relayMinMB = "relay_min_mb"
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sd2immich/config.json")

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        albumFormat = try c.decodeIfPresent(String.self, forKey: .albumFormat) ?? d.albumFormat
        videos = try c.decodeIfPresent(Bool.self, forKey: .videos) ?? d.videos
        rawOnly = try c.decodeIfPresent(Bool.self, forKey: .rawOnly) ?? d.rawOnly
        relayHost = try c.decodeIfPresent(String.self, forKey: .relayHost) ?? d.relayHost
        relayDir = try c.decodeIfPresent(String.self, forKey: .relayDir) ?? d.relayDir
        relayMinMB = try c.decodeIfPresent(Int.self, forKey: .relayMinMB) ?? d.relayMinMB
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() throws {
        let dir = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    /// "https://immich.example.com/" -> "https://immich.example.com"
    var normalizedServer: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api") { s.removeLast(4) }
        if !s.isEmpty && !s.contains("://") { s = "https://" + s }
        return s
    }
}

/// Immich API key in the login Keychain (generic password, service "sd2immich").
/// The CLI reads the same item: `security find-generic-password -s sd2immich -w`.
enum Keychain {
    static let service = "sd2immich"
    static var account: String { NSUserName() }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SD to Immich API key"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
