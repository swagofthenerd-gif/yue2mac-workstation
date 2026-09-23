//
//  Workstation.swift — where the engine pieces live, and the records they write.
//
//  The Swift app never talks to the model directly: it runs `yue2mac_engine.py`
//  (bundled in Resources/engine) with the MLX venv, and `transcribe.py` with the
//  separate SheetSage2 venv. Both print progress lines and a final `[result] {json}`.
//

import Foundation

enum Tools {
    /// Bundled engine scripts; falls back to the source tree when run unbundled.
    static var engineDir: URL {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("yue2mac_engine.py").path) {
            return res
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("YuE2Mac/engine")
    }
    static var engineScript: String { engineDir.appendingPathComponent("yue2mac_engine.py").path }
    static var transcribeScript: String { engineDir.appendingPathComponent("transcribe.py").path }

    static var sheetSageDir: URL { AppPaths.baseDir.appendingPathComponent("SheetSage", isDirectory: true) }
    static var sheetSagePython: String { sheetSageDir.appendingPathComponent("venv/bin/python").path }
    static var sheetSageModels: String { sheetSageDir.appendingPathComponent("models").path }
    static var coverModeInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: sheetSagePython)
            && fm.fileExists(atPath: sheetSageDir.appendingPathComponent("models/SheetSage2/model.safetensors").path)
            && fm.fileExists(atPath: sheetSageDir.appendingPathComponent("models/MERT-v2-FullSong/model.safetensors").path)
    }

    /// Any ffmpeg on the machine; an Intel build is fine as a command-line tool.
    static var ffmpeg: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.pixi/bin/ffmpeg", "\(home)/.local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var recordingsDir: URL { AppPaths.outputDir.appendingPathComponent("_recordings", isDirectory: true) }
    static var scratchDir: URL { AppPaths.cacheDir.appendingPathComponent("work", isDirectory: true) }

    /// Base environment for child Python processes.
    static func pythonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"          // the bundle is read-only
        env["TIKTOKEN_CACHE_DIR"] = AppPaths.cacheDir.path
        env["HF_HUB_OFFLINE"] = "1"                    // everything is local after setup
        return env
    }
}

/// `yue2mac_engine.py abc inspect` → a quick verdict on a score.
struct ScoreCheck: Decodable, Equatable {
    var ok: Bool
    var bpm: Int?
    var seconds: Double?
    var chords: Bool
    var error: String?

    var summary: String {
        guard ok else { return "Not in YuE2's score format: \(error ?? "unknown problem")" }
        let length = seconds.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "?"
        return "Valid score · \(bpm.map { "\($0) BPM" } ?? "no tempo") · \(length) long · "
            + (chords ? "melody + chords" : "melody only")
    }
}

/// One rendered version of a song.
struct TakeRecord: Decodable, Identifiable, Hashable {
    var file: String
    var seed: Int
    var seconds: Double
    var semantic_truncated: Bool
    var id: String { file }
}

/// `song.json`, written by the engine next to the takes.
struct SongRecord: Decodable {
    struct Request: Decodable {
        var style: String
        var lyrics: String
        var cot: String
        var cot_requested: String?
        var abc_supplied: Bool?
        var tempo: Int?
        var instrumental: Bool?
    }
    struct Settings: Decodable {
        var cfg_scale: Double?
        var steps: Int?
        var max_tokens: Int?
    }
    var request: Request
    var settings: Settings
    var takes: [TakeRecord]
    var notes: [String]?
    var plan_truncated: Bool?
}

/// A finished song folder in the library.
struct SongEntry: Identifiable, Hashable {
    let folder: URL
    let date: Date
    let title: String
    let style: String
    let takes: [TakeRecord]
    let hasScore: Bool
    /// take file -> (match, coverage), when the song is a cover and was checked.
    var melodyMatch: [String: (match: Double, coverage: Double)] = [:]
    var id: URL { folder }
    var scoreURL: URL { folder.appendingPathComponent("score.abc") }
    func takeURL(_ t: TakeRecord) -> URL { folder.appendingPathComponent(t.file) }

    static func == (a: SongEntry, b: SongEntry) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }

    static func load(_ folder: URL) -> SongEntry? {
        let json = folder.appendingPathComponent("song.json")
        guard let data = try? Data(contentsOf: json),
              let rec = try? JSONDecoder().decode(SongRecord.self, from: data) else { return nil }
        let date = (try? json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var entry = SongEntry(folder: folder, date: date, title: folder.lastPathComponent,
                              style: rec.request.style, takes: rec.takes,
                              hasScore: FileManager.default.fileExists(atPath: folder.appendingPathComponent("score.abc").path))
        if let m = try? Data(contentsOf: folder.appendingPathComponent("melody-match.json")),
           let obj = try? JSONSerialization.jsonObject(with: m) as? [String: [String: Double]] {
            for (file, v) in obj { entry.melodyMatch[file] = (v["match"] ?? 0, v["coverage"] ?? 0) }
        }
        return entry
    }

    /// Every song folder under Output, newest first.
    static func library() -> [SongEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: AppPaths.outputDir, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else { return [] }
        return items.filter(\.hasDirectoryPath).compactMap(load).sorted { $0.date > $1.date }
    }
}

/// A readable, unique folder name for a new song: `2026-09-23 1542 indie pop`.
func newSongFolder(style: String) -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HHmmss"
    let words = style.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != " " })
        .joined(separator: " ")
        .split(separator: " ").prefix(4).joined(separator: " ")
    let name = "\(f.string(from: Date())) \(words.isEmpty ? "song" : String(words))"
    return AppPaths.outputDir.appendingPathComponent(name, isDirectory: true)
}

/// Run a short helper to completion and return its output. Both pipes are drained
/// on background threads so a large result can't fill the pipe and stall the child.
func runCapture(_ executable: String, _ arguments: [String]) async -> (status: Int32, out: String, err: String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.environment = Tools.pythonEnvironment()
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                cont.resume(returning: (-1, "", error.localizedDescription)); return
            }
            final class Box: @unchecked Sendable { var data = Data() }
            let errBox = Box()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            let errData = errBox.data
            p.waitUntilExit()
            cont.resume(returning: (p.terminationStatus, String(decoding: outData, as: UTF8.self),
                                    String(decoding: errData, as: UTF8.self)))
        }
    }
}

/// Check a score with the bundled YuE2 score tools (standard-library Python, no model).
func checkScore(_ text: String) async -> ScoreCheck? {
    let fm = FileManager.default
    try? fm.createDirectory(at: Tools.scratchDir, withIntermediateDirectories: true)
    let file = Tools.scratchDir.appendingPathComponent("check-\(UUID().uuidString).abc")
    guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
    defer { try? fm.removeItem(at: file) }
    let r = await runCapture(AppPaths.pythonBin.path, [Tools.engineScript, "abc", "check", file.path])
    guard r.status == 0, let data = r.out.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ScoreCheck.self, from: data)
}
