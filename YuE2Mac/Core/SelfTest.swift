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

        let mode = ProcessInfo.processInfo.environment["YUE2MAC_SELFTEST"] ?? "quick"
        if mode == "cancel" {
            // Start a long song, press Stop once it's composing, and check nothing is left behind.
            s.maxTokens = 4500; s.takes = 1; s.steps = 32
            let before = Set(SongEntry.library().map(\.folder))
            engine.run(.song, settings: s, engineRoot: root, modelDir: model)
            while engine.phase != .ar && engine.isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let stoppedAt = "\(engine.phase)"
            engine.cancel()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let pythons = await runCapture("/usr/bin/pgrep", ["-f", "yue2mac_engine.py"])
            let outFolders = (try? FileManager.default.contentsOfDirectory(at: AppPaths.outputDir, includingPropertiesForKeys: nil)) ?? []
            let leftovers = outFolders.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("_") && !before.contains($0) }
            results["cancel"] = ["phase_when_stopped": stoppedAt, "phase_after": "\(engine.phase)",
                                 "engine_processes_left": pythons.out.trimmingCharacters(in: .whitespacesAndNewlines),
                                 "new_empty_folders_left": leftovers.map(\.lastPathComponent)]
            suite.removePersistentDomain(forName: "yue2mac.selftest")
            return finish(report, results)
        }
        if mode == "tools" {
            // Everything around a song: AI edit, sections, arrange, stems, lyrics check, isolated cover.
            let side = SideTasks()
            let songDir = ProcessInfo.processInfo.environment["YUE2MAC_SELFTEST_SONG"] ?? ""
            let song = SongEntry.load(URL(fileURLWithPath: songDir))
            let score = (try? String(contentsOf: URL(fileURLWithPath: songDir).appendingPathComponent("score.abc"))) ?? ""
            let (edited, res) = await side.aiEdit(score: score, instruction: "Make the chords more colourful with seventh chords and one secondary dominant",
                                                  contract: .keepMelody, style: "lo-fi hip hop")
            results["ai_edit"] = ["ok": edited != nil, "attempts": res?.attempts ?? 0,
                                  "melody_unchanged": res?.melody_unchanged ?? false, "message": side.message ?? ""]
            let secs = await side.sections(of: score)
            results["sections"] = secs.map { "\($0.name) \(Int($0.seconds ?? 0))s" }
            let order = secs.map(\.index) + [secs.last?.index ?? 0]
            let arranged = await side.arrange(score, order: order)
            results["arrange"] = ["ok": arranged != nil,
                                  "check": arranged == nil ? "" : ((await checkScore(arranged!))?.summary ?? "")]
            if let song, let t = song.takes.first {
                let stems = await side.stems(of: song.takeURL(t))
                results["stems"] = stems.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] } ?? ["failed: \(side.message ?? "")"]
                let rep = await side.lyricsCheck(take: song.takeURL(t), lyrics: "[Verse]\nquiet rooms and borrowed light\n[Chorus]\nhold on, hold on")
                results["lyrics"] = rep.map { ["found": $0.words_found, "of": $0.words_intended, "heard": $0.heard] as [String: Any] }
                    ?? ["failed": side.message ?? ""]
            }
            if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 2 < CommandLine.arguments.count {
                s.referenceAudio = CommandLine.arguments[i + 2]; s.isolateVocals = true; s.customABC = ""
                engine.run(.transcribeOnly, settings: s, engineRoot: root, modelDir: model)
                await wait()
                results["isolated_cover"] = ["phase": "\(engine.phase)", "notes": engine.notes, "score_chars": s.customABC.count]
            }
            suite.removePersistentDomain(forName: "yue2mac.selftest")
            return finish(report, results)
        }
        if mode == "full" {
            // A normal song at the model's standard quality, length fitted to its own score.
            s.maxTokens = 4500; s.autoLength = true; s.takes = 1; s.steps = 32; s.cfgScale = 1.0
            s.temperature = 1.0; s.topP = 0.95
            let t0 = Date()
            engine.run(.song, settings: s, engineRoot: root, modelDir: model)
            await wait()
            results["full"] = ["phase": "\(engine.phase)", "seconds_taken": Int(Date().timeIntervalSince(t0)),
                               "folder": engine.lastSong?.folder.path ?? "",
                               "takes": engine.lastSong?.takes.map { ["seconds": $0.seconds, "truncated": $0.semantic_truncated] } ?? [],
                               "notes": engine.notes, "failure": engine.phase == .failed ? engine.failureReason : ""]
            suite.removePersistentDomain(forName: "yue2mac.selftest")
            return finish(report, results)
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
