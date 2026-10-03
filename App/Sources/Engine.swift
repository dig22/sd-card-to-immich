import Foundation

/// A mounted camera card and what would be imported from it (see `CardScanner`).
struct CardInfo: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let raw: Int
    let jpg: Int
    let videos: Int
    let bytes: Int64
    var id: String { path }
    var totalItems: Int { raw + jpg + videos }
}

/// One JSON line from `sd2immich.py --json`.
struct EngineEvent: Decodable {
    let type: String
    let text: String
    var n: Int?
    var total: Int?
    var fraction: Double?
    var new: Int?
    var existing: Int?
    var user: String?
}

enum EngineError: LocalizedError {
    case noPython
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPython:
            return "Python 3 was not found. Install Xcode Command Line Tools (xcode-select --install) or Python from python.org."
        case .failed(let msg):
            return msg
        }
    }
}

/// Runs the bundled Python engine. The app owns the UI, settings and Keychain; the
/// engine does the scanning, de-duplication and uploading.
enum Engine {
    static var script: URL {
        Bundle.main.url(forResource: "sd2immich", withExtension: "py")!
    }

    static var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func makeProcess(_ args: [String], apiKey: String?) throws -> Process {
        guard let python else { throw EngineError.noPython }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if let apiKey { env["IMMICH_API_KEY"] = apiKey }  // never on the command line
        p.environment = env
        return p
    }

    /// Runs to completion and returns stdout (used for --check).
    static func run(_ args: [String], apiKey: String? = nil) async throws -> Data {
        let p = try makeProcess(args, apiKey: apiKey)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { _ in
                cont.resume(returning: out.fileHandleForReading.readDataToEndOfFile())
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Checks the saved server and the given key; returns the Immich user name.
    static func check(apiKey: String) async throws -> String {
        let data = try await run(["--check"], apiKey: apiKey)
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        guard let ev = try? JSONDecoder().decode(EngineEvent.self, from: Data(line.utf8)) else {
            throw EngineError.failed("No answer from the engine.")
        }
        if ev.type == "ok" { return ev.user ?? "?" }
        throw EngineError.failed(ev.text)
    }

    /// Starts an import and streams its events. Returns the process so it can be cancelled.
    static func startImport(args: [String], apiKey: String,
                            onEvent: @escaping (EngineEvent) -> Void,
                            onExit: @escaping (Int32) -> Void) throws -> Process {
        let p = try makeProcess(args + ["--json"], apiKey: apiKey)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let ev = try? JSONDecoder().decode(EngineEvent.self, from: line) {
                    onEvent(ev)
                } else if let s = String(data: line, encoding: .utf8), !s.isEmpty {
                    onEvent(EngineEvent(type: "log", text: s))  // e.g. a Python traceback
                }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }
        try p.run()
        return p
    }
}
