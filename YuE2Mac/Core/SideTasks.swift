//
//  SideTasks.swift — the quick tools around a song that don't need the music model:
//  AI score edits (Claude CLI), section arranging, stems and the lyrics check.
//  Each runs a helper script and reads its final `[result] {json}` line.
//

import Foundation

struct ScoreSection: Decodable, Identifiable, Hashable {
    var index: Int
    var name: String
    var seconds: Double?
    var id: Int { index }
}

struct LyricsReport: Decodable {
    struct Line: Decodable, Hashable { var line: String; var found: Int; var words: Int }
    struct Segment: Decodable, Hashable { var start: Double; var end: Double; var text: String }
    var word_error_rate: Double
    var words_intended: Int
    var words_found: Int
    var heard: String
    var lines: [Line]
    var segments: [Segment]
    var language: String?
}

struct AIEditResult: Decodable {
    var ok: Bool
    var file: String?
    var explanation: String
    var problems: [String]
    var attempts: Int
    var melody_unchanged: Bool
}

enum AIContract: String, CaseIterable, Identifiable {
    case keepMelody = "keep-melody", keepRhythm = "keep-rhythm", free
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keepMelody: return "Keep the melody exactly"
        case .keepRhythm: return "Keep the rhythm, notes may change"
        case .free: return "Free rewrite"
        }
    }
}

final class SideTasks: ObservableObject {
    @Published var busy: String?
    @Published var message: String?

    static var claudeCLI: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var toolsInstalled: Bool {
        let models = Tools.sheetSageDir.appendingPathComponent("models")
        return Tools.coverModeInstalled
            && FileManager.default.fileExists(atPath: models.appendingPathComponent("whisper-large-v3-turbo/config.json").path)
            && FileManager.default.fileExists(atPath: models.appendingPathComponent("hf/hub/models--adefossez--HTDemucs").path)
    }

    private static func resultJSON(_ stderr: String) -> Data? {
        guard let line = stderr.split(separator: "\n").last(where: { $0.hasPrefix("[result] ") }) else { return nil }
        return String(line.dropFirst("[result] ".count)).data(using: .utf8)
    }

    private static func lastError(_ stderr: String) -> String {
        stderr.split(separator: "\n").map(String.init)
            .last(where: { !$0.hasPrefix("[") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Unknown error"
    }

    private func scratch(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: Tools.scratchDir, withIntermediateDirectories: true)
        return Tools.scratchDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
    }

    @MainActor private func begin(_ what: String) { busy = what; message = nil }
    @MainActor private func end(_ msg: String?) { busy = nil; message = msg }

    // MARK: AI edit

    @MainActor
    func aiEdit(score: String, instruction: String, contract: AIContract, style: String) async -> (String?, AIEditResult?) {
        guard let claude = Self.claudeCLI else {
            end("The Claude CLI wasn't found (~/.local/bin/claude)."); return (nil, nil)
        }
        begin("Claude is editing the score…")
        let src = scratch("src.abc"), out = scratch("edited.abc")
        try? score.write(to: src, atomically: true, encoding: .utf8)
        let r = await runCapture(AppPaths.pythonBin.path,
                                 [Tools.engineDir.appendingPathComponent("score_editor.py").path,
                                  "--score", src.path, "--instruction", instruction, "--contract", contract.rawValue,
                                  "--style", style, "--out", out.path, "--claude", claude])
        let res = Self.resultJSON(r.err).flatMap { try? JSONDecoder().decode(AIEditResult.self, from: $0) }
        let edited = (res?.ok == true) ? try? String(contentsOf: out, encoding: .utf8) : nil
        if let res {
            end(res.ok ? nil : "Claude's edit didn't pass the checks after \(res.attempts) tries: \(res.problems.first ?? "")")
        } else {
            end(Self.lastError(r.err))
        }
        return (edited, res)
    }

    // MARK: Sections

    @MainActor
    func sections(of score: String) async -> [ScoreSection] {
        let src = scratch("sections.abc")
        try? score.write(to: src, atomically: true, encoding: .utf8)
        let r = await runCapture(AppPaths.pythonBin.path, [Tools.engineScript, "abc", "sections", src.path])
        guard r.status == 0, let data = r.out.data(using: .utf8) else { message = Self.lastError(r.err); return [] }
        return (try? JSONDecoder().decode([ScoreSection].self, from: data)) ?? []
    }

    @MainActor
    func arrange(_ score: String, order: [Int]) async -> String? {
        let src = scratch("arrange-in.abc"), out = scratch("arrange-out.abc")
        try? score.write(to: src, atomically: true, encoding: .utf8)
        let r = await runCapture(AppPaths.pythonBin.path, [Tools.engineScript, "abc", "arrange", src.path,
                                                           "--order", order.map(String.init).joined(separator: ","),
                                                           "--output", out.path])
        guard r.status == 0 else { message = Self.lastError(r.err); return nil }
        return try? String(contentsOf: out, encoding: .utf8)
    }

    // MARK: Audio tools

    private func audioTool(_ args: [String]) async -> (status: Int32, out: String, err: String) {
        var full = [Tools.engineDir.appendingPathComponent("audio_tools.py").path,
                    "--models", Tools.sheetSageModels, "--ffmpeg", Tools.ffmpeg ?? "ffmpeg"]
        full += args
        return await runCapture(Tools.sheetSagePython, full)
    }

    @MainActor
    func stems(of take: URL) async -> URL? {
        guard Self.toolsInstalled else { end("Install the audio tools first: Settings → Install Cover Mode."); return nil }
        begin("Splitting into stems…")
        let dir = take.deletingLastPathComponent()
            .appendingPathComponent("stems-" + take.deletingPathExtension().lastPathComponent)
        let r = await audioTool(["stems", take.path, "--out", dir.path])
        end(r.status == 0 ? "Stems saved: vocals, drums, bass, other" : Self.lastError(r.err))
        return r.status == 0 ? dir : nil
    }

    @MainActor
    func lyricsCheck(take: URL, lyrics: String) async -> LyricsReport? {
        guard Self.toolsInstalled else { end("Install the audio tools first: Settings → Install Cover Mode."); return nil }
        begin("Listening to what was sung…")
        let lyr = scratch("lyrics.txt")
        try? lyrics.write(to: lyr, atomically: true, encoding: .utf8)
        let report = take.deletingPathExtension().appendingPathExtension("lyrics-check.json")
        let r = await audioTool(["lyrics", take.path, "--lyrics-file", lyr.path, "--isolate",
                                 "--work", Tools.scratchDir.path, "--out", report.path])
        let res = Self.resultJSON(r.err).flatMap { try? JSONDecoder().decode(LyricsReport.self, from: $0) }
        end(res == nil ? Self.lastError(r.err) : nil)
        return res
    }

    /// Isolate the vocal of a reference before transcription (used by the cover job).
    static func isolateVocals(_ audio: URL) async -> URL? {
        let out = Tools.scratchDir.appendingPathComponent("vocals-\(UUID().uuidString.prefix(8)).wav")
        try? FileManager.default.createDirectory(at: Tools.scratchDir, withIntermediateDirectories: true)
        let r = await runCapture(Tools.sheetSagePython,
                                 [Tools.engineDir.appendingPathComponent("audio_tools.py").path,
                                  "--models", Tools.sheetSageModels, "--ffmpeg", Tools.ffmpeg ?? "ffmpeg",
                                  "vocals", audio.path, "--out", out.path])
        return r.status == 0 ? out : nil
    }
}
