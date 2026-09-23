//
//  SelfTest.swift — `YuE2Mac --selftest <report.json> [reference-audio]` drives the
//  real job runner end to end with throwaway settings (a separate defaults suite),
//  then writes what happened and quits. Used to verify builds without clicking.
//

import AppKit
import Foundation

enum SelfTest {
    static var reportPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(report: String) async {
        let suite = UserDefaults(suiteName: "yue2mac.selftest")!
        suite.removePersistentDomain(forName: "yue2mac.selftest")
        let s = SettingsStore(defaults: suite)
        let real = SettingsStore.shared
        guard let root = real.engineRoot, let model = real.modelDir else {
            return finish(report, ["error": "engine not set up"])
        }
        s.style = "lo-fi hip hop, mellow piano, vinyl crackle, soft female vocal, 80 BPM"
        s.lyrics = "[Verse]\nquiet rooms and borrowed light\n[Chorus]\nhold on, hold on"
        s.maxTokens = 300; s.autoLength = false; s.steps = 4; s.takes = 2; s.seed = "42"
        s.temperature = 0.9; s.topP = 0.9
        var results: [String: Any] = [:]
        let engine = GenerationEngine()

        func wait() async {
            while engine.isRunning || engine.phase == .idle { try? await Task.sleep(nanoseconds: 200_000_000) }
        }

        // 1. Cover transcription (only when a reference file was given).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 2 < args.count {
            s.referenceAudio = args[i + 2]
            engine.run(.transcribeOnly, settings: s, engineRoot: root, modelDir: model)
            await wait()
            results["transcribe"] = ["phase": "\(engine.phase)", "score_chars": s.customABC.count,
                                     "notes": engine.notes, "failure": engine.phase == .failed ? engine.failureReason : ""]
        }

        // 2. Two takes from the score (or a fresh plan), tempo change, fixed seed.
        if s.hasScore { s.tempoOverride = true; s.tempoBPM = 92 }
        engine.run(.song, settings: s, engineRoot: root, modelDir: model)
        await wait()
        results["song"] = ["phase": "\(engine.phase)", "folder": engine.lastSong?.folder.path ?? "",
                           "takes": engine.lastSong?.takes.map { ["file": $0.file, "seed": $0.seed, "seconds": $0.seconds] } ?? [],
                           "notes": engine.notes, "failure": engine.phase == .failed ? engine.failureReason : ""]

        // 3. Score-only plan, instrumental off.
        s.customABC = ""; s.referenceAudio = ""
        engine.run(.scoreOnly, settings: s, engineRoot: root, modelDir: model)
        await wait()
        results["plan"] = ["phase": "\(engine.phase)", "score_chars": s.customABC.count,
                           "check": (await checkScore(s.customABC)).map { $0.summary } ?? "no check",
                           "failure": engine.phase == .failed ? engine.failureReason : ""]

        // 4. Export the first take to MP3, mastered.
        if let song = engine.lastSong, let t = song.takes.first {
            switch await Exporter.export(song.takeURL(t), as: .mp3, master: true) {
            case .success(let u): results["export"] = u.path
            case .failure(let e): results["export"] = e.message
            }
        }
        results["library_count"] = SongEntry.library().count
        suite.removePersistentDomain(forName: "yue2mac.selftest")
        finish(report, results)
    }

    private static func finish(_ path: String, _ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
