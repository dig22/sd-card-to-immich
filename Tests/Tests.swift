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
    touch(root.appendingPathComponent("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG"))
    touch(root.appendingPathComponent("PRIVATE/DATABASE/DATABASE.BIN"))  // camera database: must survive
    return root
}

func names(_ files: [MediaFile]) -> [String] { files.map(\.url.lastPathComponent).sorted() }

func byNameIn(_ card: CardInfo) -> [String: MediaFile] {
    Dictionary(uniqueKeysWithValues: card.files.map { ($0.url.lastPathComponent, $0) })
}

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
    var tst = Dictionary(uniqueKeysWithValues: all.files.map { ($0.url, FileStatus.inImmich) })
    tst[all.files[0].url] = .trashed
    let tv = AppModel.verdict(card: c, statuses: tst)
    check(!tv.safe && tv.message.contains("Immich's trash"), "NOT safe when an item is only in Immich's trash", tv.message)
    for x in all.files { st[x.url] = .inImmich }
    let excluded = AppModel.verdict(card: CardInfo(path: card.path, name: "CARD", files: all.files, excludedVideos: 2), statuses: st)
    check(!excluded.safe && excluded.message.contains("2 videos (Import videos is off)"), "not safe when settings left videos out",
          excluded.message)

    print("Free up space")
    let base = card.resolvingSymlinksInPath().path
    func rel(_ u: URL) -> String { String(u.resolvingSymlinksInPath().path.dropFirst(base.count + 1)) }
    eq(FreeSpace.companions(of: byName["DSC00001.ARW"]!).map(rel), ["DCIM/100MSDCF/DSC00001.JPG"], "a RAW's companion is its JPEG twin")
    eq(FreeSpace.companions(of: byName["C0001.MP4"]!).map(rel).sorted(),
       ["PRIVATE/M4ROOT/CLIP/C0001M01.XML", "PRIVATE/M4ROOT/THMBNL/C0001T01.JPG"], "a Sony clip's companions are its XML and thumbnail")
    eq(FreeSpace.companions(of: byName["GX010001.MP4"]!).map(rel), ["DCIM/100GOPRO/GL010001.LRV"], "a GoPro clip's companion is its LRV proxy")
    eq(FreeSpace.companions(of: byName["DSC00003.ARW"]!), [], "a RAW without a JPEG has no companions")
    let fcard = CardInfo(path: card.path, name: "CARD", files: all.files)
    let plan = FreeSpace.plan(card: fcard, verified: [byName["DSC00001.ARW"]!.url, byName["C0001.MP4"]!.url])
    eq(plan.delete.map(rel).sorted(), ["DCIM/100MSDCF/DSC00001.ARW", "DCIM/100MSDCF/DSC00001.JPG", "PRIVATE/M4ROOT/CLIP/C0001.MP4",
                                       "PRIVATE/M4ROOT/CLIP/C0001M01.XML", "PRIVATE/M4ROOT/THMBNL/C0001T01.JPG"],
       "plan = verified files + their companions only")
    check(plan.bytes > 300_000, "plan counts the bytes it frees", "\(plan.bytes)")
    eq(FreeSpace.plan(card: fcard, verified: []).delete, [], "nothing verified, nothing planned")
    // Real deletion, on a copy of the card.
    let copy = URL(fileURLWithPath: card.path + "-copy")
    try? FileManager.default.removeItem(at: copy)
    try! FileManager.default.copyItem(at: card, to: copy)
    defer { try? FileManager.default.removeItem(at: copy) }
    let copyFiles = CardScanner.pickFiles(volume: copy, videos: true, rawOnly: false).files
    let ccard = CardInfo(path: copy.path, name: "COPY", files: copyFiles)
    let cby = Dictionary(uniqueKeysWithValues: copyFiles.map { ($0.url.lastPathComponent, $0.url) })
    let cplan = FreeSpace.plan(card: ccard, verified: [cby["DSC00001.ARW"]!, cby["C0001.MP4"]!])
    let result = FreeSpace.execute(cplan)
    eq(result.deleted, 5, "deletes exactly the planned files")
    check(result.failed.isEmpty, "no deletion failures")
    let left = (FileManager.default.enumerator(atPath: copy.path)?.allObjects as? [String] ?? [])
        .filter { !$0.hasSuffix("/") && (try? FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent($0).path)[.type] as? FileAttributeType) == .typeRegular }
        .sorted()
    eq(left, ["DCIM/100GOPRO/GL010001.LRV", "DCIM/100GOPRO/GX010001.MP4", "DCIM/100MSDCF/DSC00002.JPG", "DCIM/100MSDCF/DSC00003.ARW",
              "DCIM/100MSDCF/notes.txt", "PRIVATE/DATABASE/DATABASE.BIN"],
       "unverified files, other files and the camera database stay")
    var isDir: ObjCBool = false
    check(FileManager.default.fileExists(atPath: copy.appendingPathComponent("DCIM/100MSDCF").path, isDirectory: &isDir) && isDir.boolValue,
          "folders stay")

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

        print("Free up space (integration)")
        let none = try await FreeSpace.verify(card.files, client: client)
        check(none.verified.isEmpty && none.trashed.isEmpty, "files that are not in Immich are never verified", "\(none.verified.count)")
        if let path = env["IMMICH_DUPLICATE_FILE"] {
            let inImmich = URL(fileURLWithPath: path)
            let f = MediaFile(url: inImmich, kind: FileRules.kind(inImmich) ?? .jpg,
                              size: Int64((try? inImmich.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            eq(try await FreeSpace.verify([f], client: client).verified, [inImmich], "a file that is in Immich is verified")
            if let trashed = env["IMMICH_TRASHED_FILE"] {
                let t = URL(fileURLWithPath: trashed)
                let tf = MediaFile(url: t, kind: .jpg, size: Int64((try? t.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
                let tv = try await FreeSpace.verify([tf], client: client)
                check(tv.verified.isEmpty && tv.trashed == [t], "a file in Immich's trash is NOT treated as backed up (reported as trashed)")
                // And the import/check reports it as trashed, not as "already in Immich".
                let tcard = CardInfo(path: t.deletingLastPathComponent().path, name: "TRASHCARD", files: [tf])
                let tout = try await Importer.run(card: tcard, settings: s, key: key, dryRun: true, events: ImportEvents(log: { _ in }, phase: { _, _ in }))
                eq(tout.statuses[t], .trashed, "check marks a trashed match as trashed")
                check(tout.message.contains("1 in Immich's trash") && tout.message.hasPrefix("0 new, 0 already"), "check message counts it as trashed", tout.message)
                check(!AppModel.verdict(card: tcard, statuses: tout.statuses).safe, "and the card is not safe to format")
            }

            // JPEG left on a card whose RAW was imported earlier: verified through the recorded RAW checksum.
            let saved = Ledger.url
            Ledger.url = root.appendingPathComponent("ledger/raw-shots.json")  // temporary ledger
            defer { Ledger.url = saved }
            let jpg = byNameIn(card)["DSC00002.JPG"]!
            Ledger.saveHashes([Ledger.key(jpg, CaptureDate.of(jpg)): try HashCache.sha1(f)])
            eq(try await FreeSpace.verify([jpg], client: client).verified, [jpg.url], "a JPEG whose RAW is in Immich is verified via the RAW")
            Ledger.saveHashes([:])
            check(try await FreeSpace.verify([jpg], client: client).verified.isEmpty, "the same JPEG without a recorded RAW is not")
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
