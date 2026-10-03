import Foundation

/// Finds camera cards and counts what would be imported, natively in the app.
///
/// This must run in the app process, not in the Python engine: macOS only shows the
/// "access files on a removable volume" prompt for the app itself, and silently denies
/// a helper that asks first. Once the app is allowed, the engine it launches is too.
/// The rules mirror `pick_files` in sd2immich.py.
enum CardScanner {
    static let rawExt: Set<String> = ["ARW", "SR2", "DNG", "CR3", "CR2", "NEF", "NRW", "RAF", "ORF", "RW2", "PEF"]
    static let jpgExt: Set<String> = ["JPG", "JPEG", "HEIC", "HIF"]
    static let videoExt: Set<String> = ["MP4", "MOV", "MTS", "M2TS", "AVI"]
    static let videoDirs = ["PRIVATE/M4ROOT/CLIP", "PRIVATE/AVCHD/BDMV/STREAM"]

    enum Result {
        case card(CardInfo)
        case noAccess(name: String, path: String)
    }

    /// Appends to ~/Library/Logs/SD to Immich.log (card detection is the part most
    /// affected by macOS privacy settings, so it explains itself there).
    static func diag(_ msg: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SD to Immich.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func scan(videos: Bool, rawOnly: Bool) -> [Result] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeNameKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        diag("scan: \(volumes.count) volume(s): \(volumes.map(\.path).joined(separator: ", "))")
        var out: [Result] = []
        for vol in volumes where vol.path.hasPrefix("/Volumes/") {
            let v = try? vol.resourceValues(forKeys: Set(keys))
            let removable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false)
            let name = v?.volumeName ?? vol.lastPathComponent
            let dcim = vol.appendingPathComponent("DCIM")
            let top: [String]
            do {
                top = try fm.contentsOfDirectory(atPath: vol.path)  // triggers the macOS prompt on first use
            } catch let e as NSError {
                diag("\(vol.path): removable=\(removable) cannot list: \(e.domain) \(e.code) \(e.localizedDescription)")
                if removable { out.append(.noAccess(name: name, path: vol.path)) }
                continue
            }
            var isDir: ObjCBool = false
            let hasDCIM = fm.fileExists(atPath: dcim.path, isDirectory: &isDir) && isDir.boolValue
            diag("\(vol.path): removable=\(removable) entries=\(top.count) DCIM=\(hasDCIM)")
            if !hasDCIM {
                // Listed fine but no DCIM visible: on a removable card that usually means a privacy block.
                if removable && top.contains("DCIM") { out.append(.noAccess(name: name, path: vol.path)) }
                continue
            }
            let card = count(volume: vol, name: name, videos: videos, rawOnly: rawOnly)
            diag("\(vol.path): card raw=\(card.raw) jpg=\(card.jpg) videos=\(card.videos)")
            out.append(.card(card))
        }
        return out
    }

    private static func count(volume: URL, name: String, videos: Bool, rawOnly: Bool) -> CardInfo {
        struct Shot { var raw: [Int64] = []; var jpg: [Int64] = [] }
        var shots: [String: Shot] = [:]
        var clips: [Int64] = []
        let fm = FileManager.default

        func files(under dir: URL) -> [(URL, Int64)] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { return [] }
            var out: [(URL, Int64)] = []
            for case let url as URL in e {
                let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if rv?.isRegularFile == true, !url.lastPathComponent.hasPrefix("._") {
                    out.append((url, Int64(rv?.fileSize ?? 0)))
                }
            }
            return out
        }

        for (url, size) in files(under: volume.appendingPathComponent("DCIM")) {
            let ext = url.pathExtension.uppercased()
            let key = url.deletingPathExtension().path
            if rawExt.contains(ext) { shots[key, default: Shot()].raw.append(size) }
            else if jpgExt.contains(ext) { shots[key, default: Shot()].jpg.append(size) }
            else if videoExt.contains(ext) { clips.append(size) }
        }
        if videos {
            for d in videoDirs {
                let dir = volume.appendingPathComponent(d)
                let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for url in items where videoExt.contains(url.pathExtension.uppercased()) && !url.lastPathComponent.hasPrefix("._") {
                    clips.append(Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                }
            }
        } else {
            clips = []
        }

        var raw = 0, jpg = 0
        var bytes: Int64 = clips.reduce(0, +)
        for s in shots.values {
            if !s.raw.isEmpty {
                raw += s.raw.count
                bytes += s.raw.reduce(0, +)
            } else if !rawOnly {
                jpg += s.jpg.count
                bytes += s.jpg.reduce(0, +)
            }
        }
        return CardInfo(path: volume.path, name: name, raw: raw, jpg: jpg, videos: clips.count, bytes: bytes)
    }
}
