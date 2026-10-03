// Test suite for SD to Immich, compiled together with the app sources (minus App.swift).
// Run: Tests/run.sh   (set IMMICH_URL + IMMICH_API_KEY to also run the integration checks
// against a real Immich server; nothing is stored. IMMICH_DUPLICATE_FILE = a photo that is
// already in Immich enables the real-upload check, which Immich answers with "duplicate").
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

var failures = 0
var passes = 0

func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passes += 1; print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name) \(detail())") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) { check(a == b, name, "got \(a), expected \(b)") }

/// JPEG (or TIFF saved with a RAW extension) carrying EXIF DateTimeOriginal.
func writeImage(_ url: URL, type: UTType, taken: String) {
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
    ] as CFDictionary)
    precondition(CGImageDestinationFinalize(d))
}

func touch(_ url: URL, bytes: Int = 1024) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var d = Data(count: bytes)
    d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }  // unique content
    try! d.write(to: url)
}

/// A fake camera card: Sony-style DCIM + PRIVATE, a GoPro folder, and things that must be ignored.
func makeCard() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd2immich-test-\(UUID().uuidString)")
    let dcim = root.appendingPathComponent("DCIM/100MSDCF")
    try! FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
    writeImage(dcim.appendingPathComponent("DSC00001.ARW"), type: .tiff, taken: "2026:09:30 18:05:00")  // RAW + JPEG pair
    writeImage(dcim.appendingPathComponent("DSC00001.JPG"), type: .jpeg, taken: "2026:09:30 18:05:00")
    writeImage(dcim.appendingPathComponent("DSC00002.JPG"), type: .jpeg, taken: "2026:10:01 09:30:15")  // JPEG only
    writeImage(dcim.appendingPathComponent("DSC00003.ARW"), type: .tiff, taken: "2026:10:01 23:59:59")  // RAW only
    touch(dcim.appendingPathComponent("._DSC00003.ARW"), bytes: 4096)  // macOS AppleDouble junk
    touch(dcim.appendingPathComponent("notes.txt"))
    touch(root.appendingPathComponent("DCIM/100GOPRO/GX010001.MP4"), bytes: 200_000)
    touch(root.appendingPathComponent("DCIM/100GOPRO/GL010001.LRV"), bytes: 50_000)  // GoPro proxy: ignore
    touch(root.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), bytes: 300_000)
    touch(root.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001M01.XML"))
    return root
}

func names(_ files: [MediaFile]) -> [String] { files.map(\.url.lastPathComponent).sorted() }

@MainActor
func runUnitTests() {
    let card = makeCard()
    defer { try? FileManager.default.removeItem(at: card) }

    print("File picking")
    let all = CardScanner.pickFiles(volume: card, videos: true, rawOnly: false)
    eq(names(all.files), ["C0001.MP4", "DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW", "GX010001.MP4"],
       "RAW kept, JPEG twin dropped, JPEG-only kept, videos from DCIM and Sony CLIP, junk ignored")
    eq(all.excludedJPG, 0, "nothing excluded by default (JPEG)")
    eq(all.excludedVideos, 0, "nothing excluded by default (video)")
    let rawOnly = CardScanner.pickFiles(volume: card, videos: true, rawOnly: true)
    eq(names(rawOnly.files), ["C0001.MP4", "DSC00001.ARW", "DSC00003.ARW", "GX010001.MP4"], "RAW only skips JPEG-only shots")
    eq(rawOnly.excludedJPG, 1, "RAW only counts the excluded JPEG")
    let noVideo = CardScanner.pickFiles(volume: card, videos: false, rawOnly: false)
    eq(names(noVideo.files), ["DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW"], "videos off drops all clips")
    eq(noVideo.excludedVideos, 2, "videos off counts both excluded clips")

    print("Capture dates")
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let byName = Dictionary(uniqueKeysWithValues: all.files.map { ($0.url.lastPathComponent, $0) })
    eq(fmt.string(from: CaptureDate.of(byName["DSC00001.ARW"]!)), "2026-09-30 18:05:00", "EXIF date from a TIFF-based RAW")
    eq(fmt.string(from: CaptureDate.of(byName["DSC00002.JPG"]!)), "2026-10-01 09:30:15", "EXIF date from a JPEG")
    eq(fmt.string(from: CaptureDate.of(byName["DSC00003.ARW"]!)), "2026-10-01 23:59:59", "late-evening shot keeps its own day")
    let clip = byName["C0001.MP4"]!
    let mtime = try! clip.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    eq(CaptureDate.of(clip), mtime, "videos use the file date")

    print("Settings")
    var s = AppSettings()
    let day = fmt.date(from: "2026-10-02 08:00:00")!
    eq(s.albumName(for: day), "2026-10-02", "default album name")
    s.albumFormat = "%d %b %Y"
    eq(s.albumName(for: day), "02 Oct 2026", "custom album format")
    s.albumFormat = "Trip %Y"
    eq(s.albumName(for: day), "Trip 2026", "literal text in album format")
    s.albumFormat = "%Y-%m-%d %a's"
    eq(s.albumName(for: day), "2026-10-02 Fri's", "apostrophes and mixed text")
    s.albumFormat = "100% %Y"
    eq(s.albumName(for: day), "100% 2026", "a lone % stays literal")
    s.server = "photos.example.com/"
    eq(s.normalizedServer, "https://photos.example.com", "server without scheme gets https, trailing slash removed")
    s.server = "https://photos.example.com/api/"
    eq(s.normalizedServer, "https://photos.example.com", "trailing /api removed")
    let json = try! JSONEncoder().encode(AppSettings())
    let keys = (try! JSONSerialization.jsonObject(with: json) as! [String: Any]).keys.sorted()
    eq(keys, ["album_format", "auto_import", "eject_when_done", "raw_only", "relay_dir", "relay_host", "relay_min_mb", "server", "videos"],
       "config file keys")
    let old = try! JSONDecoder().decode(AppSettings.self, from: Data(#"{"server":"https://x"}"#.utf8))
    check(old.server == "https://x" && !old.autoImport && old.videos, "older config files load with defaults")

    print("Upload fields, ledger, checksums")
    let f = byName["DSC00002.JPG"]!
    let fields = Dictionary(uniqueKeysWithValues: ImmichClient.uploadFields(f, created: CaptureDate.of(f)))
    check(fields["fileCreatedAt"]!.range(of: #"^2026-10-01T09:30:15([+-]\d\d:\d\d|Z)$"#, options: .regularExpression) != nil,
          "fileCreatedAt is ISO 8601 with a timezone", fields["fileCreatedAt"]!)
    eq(fields["filename"]!, "DSC00002.JPG", "filename field")
    eq(Ledger.key(byName["DSC00001.ARW"]!, CaptureDate.of(byName["DSC00001.ARW"]!)), "DSC00001|2026-09-30T18:05:00",
       "ledger key = name + capture time")
    eq(Ledger.key(MediaFile(url: card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"), kind: .jpg, size: 1),
                  CaptureDate.of(byName["DSC00001.ARW"]!)), "DSC00001|2026-09-30T18:05:00",
       "a JPEG twin maps to its RAW's ledger key")
    let data = try! Data(contentsOf: f.url)
    let expected = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    eq(try! HashCache.sha1(f), expected, "SHA-1 matches")
    eq(try! HashCache.sha1(f), expected, "SHA-1 from cache matches")

    print("Safe to format")
    let c = CardInfo(path: card.path, name: "CARD", files: all.files)
    var st: [URL: FileStatus] = [:]
    for x in all.files { st[x.url] = .inImmich }
    check(AppModel.verdict(card: c, statuses: st).safe, "safe when everything is in Immich")
    let one = CardInfo(path: card.path, name: "CARD", files: [all.files[0]])
    eq(AppModel.verdict(card: one, statuses: [all.files[0].url: .inImmich]).message,
       "The only item on CARD is in Immich. It's safe to format the card in your camera.", "singular wording")
    st[all.files[0].url] = .skipped("RAW already imported")
    check(AppModel.verdict(card: c, statuses: st).safe, "skipped twins/duplicates still count as safe")
    st[all.files[1].url] = .new
    let notYet = AppModel.verdict(card: c, statuses: st)
    check(!notYet.safe && notYet.message.contains("1 item is not in Immich"), "not safe with one new item", notYet.message)
    st[all.files[1].url] = .failed
    check(!AppModel.verdict(card: c, statuses: st).safe, "not safe after a failed upload")
    check(!AppModel.verdict(card: c, statuses: [:]).safe, "not safe before anything was checked")
    for x in all.files { st[x.url] = .inImmich }
    let excluded = AppModel.verdict(card: CardInfo(path: card.path, name: "CARD", files: all.files, excludedVideos: 2), statuses: st)
    check(!excluded.safe && excluded.message.contains("2 videos (Import videos is off)"), "not safe when settings left videos out",
          excluded.message)

    print("Time left / speed")
    let now = Date()
    let mb: Int64 = 1_000_000
    let t1 = AppModel.transferText(done: 100 * mb, total: 1_300 * mb, samples: [(now.addingTimeInterval(-10), 40 * mb)], now: now)
    check(t1.contains("1.2 GB left") && t1.contains("~3 min") && t1.contains("6 MB/s"), "1.2 GB at 6 MB/s ≈ 3 min", t1)
    let t2 = AppModel.transferText(done: 0, total: 500 * mb, samples: [(now, 0)], now: now)
    eq(t2, "500 MB left", "no speed shown until there is enough data")
    let t3 = AppModel.transferText(done: 990 * mb, total: 1_000 * mb, samples: [(now.addingTimeInterval(-5), 900 * mb)], now: now)
    check(t3.contains("less than a minute"), "short remainder", t3)
}

func runIntegration() async {
    let env = ProcessInfo.processInfo.environment
    guard let server = env["IMMICH_URL"], let key = env["IMMICH_API_KEY"] else {
        print("Integration (skipped: set IMMICH_URL and IMMICH_API_KEY)")
        return
    }
    print("Integration (nothing stored, \(server))")
    do {
        let client = try ImmichClient(server: server, key: key)
        check(!(try await client.me()).isEmpty, "API key works (users/me)")
        let bad = try ImmichClient(server: server, key: "not-a-key")
        do { _ = try await bad.me(); check(false, "wrong key is rejected") } catch { check(true, "wrong key is rejected") }

        let root = makeCard()
        defer { try? FileManager.default.removeItem(at: root) }
        var s = AppSettings()
        s.server = server
        let picked = CardScanner.pickFiles(volume: root, videos: true, rawOnly: false)
        let card = CardInfo(path: root.path, name: "TESTCARD", files: picked.files)
        var events = ImportEvents(log: { _ in }, phase: { _, _ in })
        var sawBytes = false
        events.bytes = { _, _ in sawBytes = true }
        let out = try await Importer.run(card: card, settings: s, key: key, dryRun: true, events: events)
        check(out.message.hasPrefix("5 new, 0 already in Immich"), "dry run finds the 5 new test files", out.message)
        eq(out.statuses.count, 5, "dry run reports a status for every file")
        check(out.statuses.values.allSatisfy { $0 == .new }, "all marked new")
        check(sawBytes, "progress bytes are reported")
        check(!AppModel.verdict(card: card, statuses: out.statuses).safe, "dry run of new files is not 'safe to format'")

        // Real multipart upload without storing anything: re-upload a file Immich already has.
        // Immich parses and validates the whole request (fields, dates, file) and answers
        // "duplicate". (A fake/empty/.txt file can't prove this: Immich rejects those before
        // it validates the fields.)
        if let path = env["IMMICH_DUPLICATE_FILE"] {
            let url = URL(fileURLWithPath: path)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let f = MediaFile(url: url, kind: FileRules.kind(url) ?? .jpg, size: size)
            var progressSeen = false
            let r = try await client.upload(f, created: CaptureDate.of(f)) { _ in progressSeen = true }
            eq(r.status, "duplicate", "full upload accepted by Immich (fields valid), recognised as duplicate, nothing stored")
            check(!r.id.isEmpty, "upload returns the asset id")
            check(progressSeen, "upload progress is reported")
        } else {
            print("  (upload check skipped: set IMMICH_DUPLICATE_FILE to a file already in Immich)")
        }
    } catch {
        check(false, "integration", "\(error)")
    }
}

@main
struct TestMain {
    static func main() async {
        print("SD to Immich tests")
        await MainActor.run { runUnitTests() }
        await runIntegration()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
