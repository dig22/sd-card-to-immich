import Foundation
import Security

/// Non-secret settings in ~/.config/sd2immich/config.json (0600). The API key is NOT
/// stored here; see `Keychain`.
struct AppSettings: Codable, Equatable {
    var server: String = ""
    var albumFormat: String = "%Y-%m-%d"
    var videos: Bool = true
    var rawOnly: Bool = false
    var relayHost: String = ""
    var relayDir: String = ".cache/sd2immich"
    var relayMinMB: Int = 300
    var autoImport: Bool = false
    var ejectWhenDone: Bool = false

    enum CodingKeys: String, CodingKey {
        case server, videos
        case autoImport = "auto_import"
        case ejectWhenDone = "eject_when_done"
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
        autoImport = try c.decodeIfPresent(Bool.self, forKey: .autoImport) ?? d.autoImport
        ejectWhenDone = try c.decodeIfPresent(Bool.self, forKey: .ejectWhenDone) ?? d.ejectWhenDone
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

    /// Album name for a capture date, from the strftime-style `albumFormat`.
    func albumName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = strftimeToDateFormat(albumFormat.isEmpty ? "%Y-%m-%d" : albumFormat)
        return f.string(from: date)
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

/// Immich API key in the login Keychain (generic password, service "sd-card-to-immich").
///
/// The item is created by the app itself, so reading it normally needs no confirmation.
/// macOS asks again only when the app's code signature changes (an update of this
/// unsigned app); `AppModel.withKey` explains that before the first read of a version.
enum Keychain {
    static let service = "sd-card-to-immich"
    static var account: String { NSUserName() }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether a key is stored. Asks only for attributes, which never shows a prompt.
    static func exists() -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
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

    /// Replaces the item (delete + add) so this app build owns it and can read it silently.
    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "SD to Immich: Immich API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// strftime ("%Y-%m-%d") -> DateFormatter pattern ("yyyy-MM-dd"). Literal text is quoted
/// as whole runs ("Trip %Y" -> "'Trip 'yyyy"), since DateFormatter treats letters as fields.
func strftimeToDateFormat(_ s: String) -> String {
    let map: [Character: String] = ["Y": "yyyy", "y": "yy", "m": "MM", "d": "dd", "e": "d", "b": "MMM", "B": "MMMM",
                                    "a": "EEE", "A": "EEEE", "H": "HH", "M": "mm", "j": "DDD", "%": "%"]
    var out = ""
    var literal = ""
    func flush() {
        guard !literal.isEmpty else { return }
        out += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
        literal = ""
    }
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "%", s.index(after: i) < s.endIndex, let field = map[s[s.index(after: i)]] {
            flush()
            out += field == "%" ? "'%'" : field
            i = s.index(i, offsetBy: 2)
        } else {
            literal.append(s[i])
            i = s.index(after: i)
        }
    }
    flush()
    return out
}
