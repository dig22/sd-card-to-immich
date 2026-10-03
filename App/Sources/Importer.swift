import CryptoKit
import Foundation
import ImageIO

// MARK: - File rules

enum MediaKind { case raw, jpg, video }

enum FileRules {
    static let raw: Set<String> = ["ARW", "SR2", "DNG", "CR3", "CR2", "NEF", "NRW", "RAF", "ORF", "RW2", "PEF"]
    static let jpg: Set<String> = ["JPG", "JPEG", "HEIC", "HIF"]
    static let video: Set<String> = ["MP4", "MOV", "MTS", "M2TS", "AVI"]
    /// Sony keeps clips outside DCIM.
    static let videoDirs = ["PRIVATE/M4ROOT/CLIP", "PRIVATE/AVCHD/BDMV/STREAM"]

    static func kind(_ url: URL) -> MediaKind? {
        let e = url.pathExtension.uppercased()
        if raw.contains(e) { return .raw }
        if jpg.contains(e) { return .jpg }
        if video.contains(e) { return .video }
        return nil
    }
}

struct MediaFile: Hashable {
    let url: URL
    let kind: MediaKind
    let size: Int64
}

// MARK: - Card scanning

/// A mounted camera card and what would be imported from it.
struct CardInfo: Identifiable, Hashable {
    let path: String
    let name: String
    let files: [MediaFile]
    var id: String { path }
    var raw: Int { files.filter { $0.kind == .raw }.count }
    var jpg: Int { files.filter { $0.kind == .jpg }.count }
    var videos: Int { files.filter { $0.kind == .video }.count }
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum CardScanner {
    enum Result {
        case card(CardInfo)
        case noAccess(name: String)
    }

    static func scan(videos: Bool, rawOnly: Bool) -> [Result] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        Log.write("scan: \(volumes.map(\.path).joined(separator: ", "))")
        var out: [Result] = []
        for vol in volumes where vol.path.hasPrefix("/Volumes/") {
            let v = try? vol.resourceValues(forKeys: Set(keys))
            let removable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false)
            let name = v?.volumeName ?? vol.lastPathComponent
            let top: [String]
            do {
                top = try fm.contentsOfDirectory(atPath: vol.path)  // first use triggers the macOS prompt
            } catch {
                Log.write("  \(vol.path): cannot list (\(error.localizedDescription))")
                if removable { out.append(.noAccess(name: name)) }
                continue
            }
            guard top.contains("DCIM") else { continue }
            let files = pickFiles(volume: vol, videos: videos, rawOnly: rawOnly)
            let card = CardInfo(path: vol.path, name: name, files: files)
            Log.write("  \(vol.path): card raw=\(card.raw) jpg=\(card.jpg) videos=\(card.videos)")
            out.append(.card(card))
        }
        return out
    }

    /// RAW for every shot; a JPEG only when its shot has no RAW (unless rawOnly); videos.
    static func pickFiles(volume: URL, videos: Bool, rawOnly: Bool) -> [MediaFile] {
        var shots: [String: [MediaFile]] = [:]
        var clips: [MediaFile] = []
        for f in regularFiles(under: volume.appendingPathComponent("DCIM")) {
            switch f.kind {
            case .video: clips.append(f)
            default: shots[f.url.deletingPathExtension().path, default: []].append(f)
            }
        }
        var chosen: [MediaFile] = []
        for group in shots.values {
            let raws = group.filter { $0.kind == .raw }
            if !raws.isEmpty { chosen += raws } else if !rawOnly { chosen += group }
        }
        if videos {
            for d in FileRules.videoDirs {
                clips += regularFiles(under: volume.appendingPathComponent(d)).filter { $0.kind == .video }
            }
            chosen += clips
        }
        return chosen.sorted { $0.url.path < $1.url.path }
    }

    private static func regularFiles(under dir: URL) -> [MediaFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [MediaFile] = []
        for case let url as URL in e where !url.lastPathComponent.hasPrefix("._") {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true,
                  let kind = FileRules.kind(url) else { continue }
            out.append(MediaFile(url: url, kind: kind, size: Int64(rv.fileSize ?? 0)))
        }
        return out
    }
}

// MARK: - Capture date

enum CaptureDate {
    /// EXIF DateTimeOriginal (RAW files are TIFF-based; JPEG/HEIC via ImageIO), else file mtime.
    static func of(_ f: MediaFile) -> Date {
        if f.kind != .video, let d = tiffDate(f.url) ?? imageIODate(f.url) { return d }
        let mtime = (try? f.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return mtime ?? Date()  // cameras write local time
    }

    private static let exifFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func imageIODate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifFormat.date(from: s)
    }

    /// Small IFD walker: IFD0 -> ExifIFD (0x8769) -> DateTimeOriginal (0x9003), or DateTime (0x0132).
    /// Works for TIFF-based RAW (ARW, NEF, DNG, CR2, ...) and JPEG (TIFF block in APP1).
    private static func tiffDate(_ url: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let buf = try? h.read(upToCount: 256 * 1024), buf.count > 16 else { return nil }
        let b = [UInt8](buf)
        var base = 0
        if b[0] == 0xFF && b[1] == 0xD8 {  // JPEG: find "Exif\0\0"
            guard let r = buf.range(of: Data("Exif\u{0}\u{0}".utf8)) else { return nil }
            base = r.upperBound
        }
        guard base + 8 < b.count else { return nil }
        let le: Bool
        switch (b[base], b[base + 1]) {
        case (0x49, 0x49): le = true
        case (0x4D, 0x4D): le = false
        default: return nil
        }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= b.count else { return nil }
            return le ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            let v = le ? (UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
                       : (UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]))
            return Int(v)
        }
        func entries(_ off: Int) -> [(tag: Int, type: Int, count: Int, value: Int)] {
            guard let n = u16(base + off), n < 1000 else { return [] }
            return (0..<n).compactMap { i in
                let e = base + off + 2 + 12 * i
                guard let t = u16(e), let ty = u16(e + 2), let c = u32(e + 4), let v = u32(e + 8) else { return nil }
                return (t, ty, c, v)
            }
        }
        guard let ifd0 = u32(base + 4) else { return nil }
        let exif = entries(ifd0).first { $0.tag == 0x8769 }?.value
        for off in [exif, ifd0].compactMap({ $0 }) {
            for e in entries(off) where (e.tag == 0x9003 || e.tag == 0x0132) && e.type == 2 && e.count >= 19 {
                let start = base + e.value
                guard start + 19 <= b.count, let s = String(bytes: b[start..<start + 19], encoding: .ascii) else { continue }
                if let d = exifFormat.date(from: s) { return d }
            }
        }
        return nil
    }
}

// MARK: - Immich API

struct ImmichError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ImmichClient {
    let base: URL
    let key: String
    private let session: URLSession

    init(server: String, key: String) throws {
        guard let u = URL(string: server + "/api") else { throw ImmichError(message: "Invalid server URL") }
        base = u
        self.key = key
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: cfg)
    }

    private func request(_ method: String, _ path: String, json: Any? = nil) throws -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// JSON call with retries for dropped connections and 5xx (a busy server thumbnailing RAWs).
    func call(_ method: String, _ path: String, json: Any? = nil, log: ((String) -> Void)? = nil) async throws -> Any {
        let req = try request(method, path, json: json)
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 500 && attempt < 5 { throw URLError(.badServerResponse) }
                guard (200..<300).contains(code) else {
                    throw ImmichError(message: "\(method) \(path) → \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
                }
                return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
            } catch let e as URLError where attempt < 5 {
                attempt += 1
                log?("    \(e.localizedDescription); retrying in \(15 * attempt)s")
                try await Task.sleep(nanoseconds: UInt64(15 * attempt) * 1_000_000_000)
            }
        }
    }

    func me() async throws -> String {
        let me = try await call("GET", "users/me") as? [String: Any]
        return (me?["name"] as? String) ?? (me?["email"] as? String) ?? "?"
    }

    static func uploadFields(_ f: MediaFile, created: Date) -> [(String, String)] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        let mtime = (try? f.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? created
        return [("deviceAssetId", "\(f.url.lastPathComponent)-\(f.size)"), ("deviceId", "sd-card-to-immich"),
                ("fileCreatedAt", iso.string(from: created)), ("fileModifiedAt", iso.string(from: mtime)),
                ("filename", f.url.lastPathComponent)]
    }

    /// Multipart upload, streamed from a temp file so big videos aren't held in memory.
    func upload(_ f: MediaFile, created: Date, progress: @escaping (Double) -> Void) async throws -> (id: String, status: String) {
        let boundary = "sd2immich-\(UUID().uuidString)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        for (k, v) in Self.uploadFields(f, created: created) {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(f.url.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: f.url)
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { out.write(chunk) }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var req = try request("POST", "assets")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var attempt = 0
        while true {
            do {
                let delegate = UploadProgress(progress)
                let (data, resp) = try await session.upload(for: req, fromFile: tmp, delegate: delegate)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code),
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String else {
                    if code >= 500 && attempt < 5 { throw URLError(.badServerResponse) }
                    throw ImmichError(message: "Upload of \(f.url.lastPathComponent) → \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
                }
                return (id, (obj["status"] as? String) ?? "created")
            } catch let e as URLError where attempt < 5 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(15 * attempt) * 1_000_000_000)
                _ = e
            }
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void
    init(_ p: @escaping (Double) -> Void) { onProgress = p }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

// MARK: - Relay for big files

/// Immich (Node) drops a request that takes more than ~5 minutes to arrive. On a slow link,
/// big files are rsynced (resumable) to an SSH host near Immich and uploaded from there.
enum Relay {
    static func upload(_ f: MediaFile, created: Date, settings: AppSettings, client: ImmichClient,
                       log: @escaping (String) -> Void) async throws -> (id: String, status: String) {
        let host = settings.relayHost, dir = settings.relayDir
        let remote = "\(dir)/\(f.url.lastPathComponent)"
        log("    \(String(format: "%.1f", Double(f.size) / 1e9)) GB: copying to \(host) first (resumable)…")
        let ssh = ["-o", "ServerAliveInterval=30", "-o", "BatchMode=yes", host]
        _ = try await run("/usr/bin/ssh", ssh + ["mkdir -p \(sh(dir))"])
        var copied = false
        for attempt in 1...5 {
            if (try? await run("/usr/bin/rsync", ["--partial", "--inplace", "--times", f.url.path, "\(host):\(remote)"])) != nil {
                copied = true
                break
            }
            log("    rsync failed (try \(attempt)); retrying in 20s")
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
        guard copied else { throw ImmichError(message: "Could not copy \(f.url.lastPathComponent) to \(host)") }
        let form = ImmichClient.uploadFields(f, created: created).map { "-F \(sh("\($0.0)=\($0.1)"))" }.joined(separator: " ")
        let api = client.base.appendingPathComponent("assets").absoluteString
        // The key goes over ssh stdin as a header: never on the relay's disk or command line.
        let cmd = "curl -sS --fail-with-body -X POST \(sh(api)) -H @- \(form) -F assetData=@\(sh(remote)); rc=$?; rm -f \(sh(remote)); exit $rc"
        let out = try await run("/usr/bin/ssh", ssh + [cmd], stdin: "x-api-key: \(client.key)\n")
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let id = obj["id"] as? String else { throw ImmichError(message: "Relay upload failed: \(out.prefix(300))") }
        return (id, (obj["status"] as? String) ?? "created")
    }

    private static func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func run(_ exe: String, _ args: [String], stdin: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = inp
            p.terminationHandler = { proc in
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { cont.resume(returning: s) }
                else { cont.resume(throwing: ImmichError(message: "\(exe) failed: \(s.prefix(300))")) }
            }
            do {
                try p.run()
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
            } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - Import

/// Remembers imported RAW shots (file name + capture time) so their JPEG twins are never
/// uploaded later, even from another card. Camera file numbers repeat, hence the time.
enum Ledger {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/sd2immich/raw-shots.json")

    static func key(_ f: MediaFile, _ taken: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return "\(f.url.deletingPathExtension().lastPathComponent.uppercased())|\(fmt.string(from: taken))"
    }

    static func load() -> Set<String> {
        guard let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }

    static func save(_ s: Set<String>) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s.sorted()).write(to: url, options: .atomic)
    }
}

/// Per-file state shown on the thumbnail tiles.
enum FileStatus: Equatable {
    case pending          // not looked at yet
    case new              // dry run: would be uploaded
    case uploading(Double)
    case inImmich         // already there, or uploaded in this run
    case skipped(String)  // JPEG whose RAW was imported, duplicate on the card
    case failed
}

struct ImportEvents {
    var log: (String) -> Void
    var phase: (String, Double) -> Void  // detail text, overall fraction 0...1
    var status: (URL, FileStatus) -> Void = { _, _ in }
}

/// SHA-1 per file, cached by name + size + modification time, so a card that was
/// already scanned (or mostly imported) isn't read in full again.
enum HashCache {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/sd2immich/hash-cache.json")
    private static var cache: [String: String] = {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }()

    private static func key(_ f: MediaFile) -> String {
        let m = (try? f.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(f.url.lastPathComponent)|\(f.size)|\(Int(m?.timeIntervalSince1970 ?? 0))"
    }

    static func sha1(_ f: MediaFile) throws -> String {
        let k = key(f)
        if let h = cache[k] { return h }
        var h = Insecure.SHA1()
        let fh = try FileHandle(forReadingFrom: f.url)
        defer { try? fh.close() }
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { h.update(data: chunk) }
        let hex = h.finalize().map { String(format: "%02x", $0) }.joined()
        cache[k] = hex
        return hex
    }

    static func save() {
        if cache.count > 50_000 { cache = [:] }  // crude bound; it refills from cards
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}

enum Importer {
    static let batchSize = 20

    /// Works in batches: fingerprint 20 files -> ask Immich which are new -> upload them ->
    /// add the batch to its day albums. Uploads start within seconds, and a cancelled run
    /// keeps everything finished so far (albums included). Returns a one-line summary.
    static func run(card: CardInfo, settings: AppSettings, key: String, dryRun: Bool,
                    events: ImportEvents) async throws -> String {
        let files = card.files
        guard !files.isEmpty else { return "No photos or videos on \(card.name)." }
        events.log("\(card.name): \(card.raw) RAW, \(card.jpg) JPG, \(card.videos) videos")

        let client = try ImmichClient(server: settings.normalizedServer, key: key)
        events.log("Immich: \(settings.normalizedServer) as \(try await client.me())")

        var ledger = Ledger.load()
        var albumId: [String: String] = [:]
        if !dryRun {
            for a in (try await client.call("GET", "albums", log: events.log) as? [[String: Any]]) ?? [] {
                if let n = a["albumName"] as? String, let id = a["id"] as? String { albumId[n] = id }
            }
        }
        var seen = Set<String>()  // hashes already handled in this run (duplicates on the card)
        var uploaded = 0, existing = 0, skippedJPG = 0, cardDupes = 0
        var albumsTouched = Set<String>(), newPerAlbum: [String: Int] = [:]
        let totalBytes = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        var doneBytes: Int64 = 0

        for start in stride(from: 0, to: files.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(files[start..<min(start + batchSize, files.count)])

            // 1. Fingerprint + capture date (cached hashes make re-scans fast).
            var items: [(file: MediaFile, hash: String, taken: Date)] = []
            for f in batch {
                try Task.checkCancellation()
                let taken = CaptureDate.of(f)
                events.phase("Checking \(f.url.lastPathComponent)…", 0.02 + 0.95 * Double(doneBytes) / Double(totalBytes))
                if f.kind == .jpg && ledger.contains(Ledger.key(f, taken)) {
                    events.status(f.url, .skipped("RAW already imported"))
                    skippedJPG += 1
                    doneBytes += f.size
                    continue
                }
                items.append((f, try HashCache.sha1(f), taken))
            }
            HashCache.save()
            let fresh = items.filter { seen.insert($0.hash).inserted }
            for i in items where !fresh.contains(where: { $0.file == i.file }) {
                events.status(i.file.url, .skipped("duplicate on card"))
            }
            cardDupes += items.count - fresh.count
            if fresh.isEmpty { continue }

            // 2. Which ones does Immich already have?
            let res = try await client.call("POST", "assets/bulk-upload-check",
                                            json: ["assets": fresh.map { ["id": $0.hash, "checksum": $0.hash] }], log: events.log)
            var assetOf: [String: String] = [:]
            var accept = Set<String>()
            for r in ((res as? [String: Any])?["results"] as? [[String: Any]]) ?? [] {
                guard let id = r["id"] as? String else { continue }
                if r["action"] as? String == "accept" { accept.insert(id) }
                else if let a = r["assetId"] as? String { assetOf[id] = a }
            }
            existing += assetOf.count
            for i in fresh {
                events.status(i.file.url, accept.contains(i.hash) ? (dryRun ? .new : .pending) : .inImmich)
            }

            if dryRun {
                for i in fresh {
                    let album = settings.albumName(for: i.taken)
                    albumsTouched.insert(album)
                    if accept.contains(i.hash) { newPerAlbum[album, default: 0] += 1; uploaded += 1 }
                    doneBytes += i.file.size
                }
                events.phase("Checked \(min(start + batchSize, files.count)) of \(files.count)…",
                             0.02 + 0.95 * Double(doneBytes) / Double(totalBytes))
                continue
            }

            // 3. Upload the new ones.
            for i in fresh {
                if accept.contains(i.hash) {
                    try Task.checkCancellation()
                    let f = i.file
                    let label = "Uploading \(f.url.lastPathComponent)"
                    let sent = doneBytes
                    let useRelay = !settings.relayHost.isEmpty && f.size > Int64(settings.relayMinMB) * 1_048_576
                    events.status(f.url, .uploading(0))
                    let r: (id: String, status: String)
                    do {
                        r = useRelay
                            ? try await Relay.upload(f, created: i.taken, settings: settings, client: client, log: events.log)
                            : try await client.upload(f, created: i.taken) { p in
                                events.status(f.url, .uploading(p))
                                events.phase(label, 0.02 + 0.95 * (Double(sent) + p * Double(f.size)) / Double(totalBytes))
                            }
                    } catch {
                        events.status(f.url, error is CancellationError ? .pending : .failed)
                        throw error
                    }
                    events.status(f.url, .inImmich)
                    assetOf[i.hash] = r.id
                    uploaded += 1
                    events.log("↑ \(f.url.lastPathComponent) \(r.status)")
                }
                if i.file.kind == .raw { ledger.insert(Ledger.key(i.file, i.taken)) }
                doneBytes += i.file.size
                events.phase("Uploaded \(uploaded), \(existing) already in Immich", 0.02 + 0.95 * Double(doneBytes) / Double(totalBytes))
            }
            Ledger.save(ledger)

            // 4. Albums for this batch.
            var members: [String: [String]] = [:]
            for i in fresh { if let a = assetOf[i.hash] { members[settings.albumName(for: i.taken), default: []].append(a) } }
            for (name, ids) in members.sorted(by: { $0.key < $1.key }) {
                albumsTouched.insert(name)
                if let id = albumId[name] {
                    _ = try await client.call("PUT", "albums/\(id)/assets", json: ["ids": ids], log: events.log)
                } else {
                    let a = try await client.call("POST", "albums", json: ["albumName": name, "assetIds": ids], log: events.log)
                    if let id = (a as? [String: Any])?["id"] as? String { albumId[name] = id }
                    events.log("Album \(name) created")
                }
            }
        }

        if skippedJPG > 0 { events.log("Skipped \(skippedJPG) JPG(s) whose RAW was imported earlier") }
        if cardDupes > 0 { events.log("Skipped \(cardDupes) duplicate file(s) on the card") }
        let albums = albumsTouched.sorted().joined(separator: ", ")
        if dryRun {
            let per = newPerAlbum.keys.sorted().map { "\($0): \(newPerAlbum[$0]!)" }.joined(separator: ", ")
            return "\(uploaded) new, \(existing) already in Immich" + (per.isEmpty ? "." : " (\(per)).")
        }
        return "Imported \(uploaded) new, \(existing) already in Immich. Albums: \(albums.isEmpty ? "none" : albums)."
    }
}

// MARK: - Log file

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SD to Immich.log")

    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
