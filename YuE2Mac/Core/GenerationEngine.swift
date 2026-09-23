//
//  GenerationEngine.swift — runs workstation jobs as child processes and turns
//  their progress lines into UI state. A job can chain steps: transcribe a
//  reference recording (SheetSage2) → write or take a score → render takes.
//  Cancellation terminates whichever step is running.
//

import Foundation

final class GenerationEngine: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, transcribing, planning, ar, nar, decoding, writing, finished, failed, cancelled
    }
    enum Job { case song, scoreOnly, transcribeOnly }

    @Published var phase: Phase = .idle
    @Published var progressMessage = ""
    /// nil = indeterminate; a value = a fraction for a determinate bar.
    @Published var progress: Double?
    @Published var logText = ""
    @Published var notes: [String] = []
    @Published var startedAt: Date?

    /// The last finished song, and what the last score-only / transcription job produced.
    @Published var lastSong: SongEntry?
    @Published var lastJob: Job = .song
    @Published var lastTranscription: URL?

    /// The main player: live sections while a song is made, then the finished takes.
    let player = Player()

    private var process: Process?
    private var runner: Task<Void, Never>?
    private var userCancelled = false

    // Progress bookkeeping for the current step.
    private var expectedTokens = 4500
    private var take = 1
    private var takes = 1
    private var planning = false

    var isRunning: Bool {
        switch phase {
        case .preparing, .transcribing, .planning, .ar, .nar, .decoding, .writing: return true
        default: return false
        }
    }

    var detailLine: String {
        switch phase {
        case .transcribing, .planning, .ar, .nar, .decoding: return progressMessage
        default: return ""
        }
    }

    /// The most useful line to show when a step fails (usually Python's final error line).
    var failureReason: String {
        let lines = logText.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("»") }
        return lines.last(where: { $0.contains("Error") || $0.contains("error") || $0.hasPrefix("SheetSage") })
            ?? lines.last ?? progressMessage
    }

    // MARK: - Jobs

    func run(_ job: Job, settings: SettingsStore, engineRoot: String, modelDir: String) {
        guard !isRunning else { return }
        userCancelled = false
        lastJob = job
        phase = .preparing
        progress = 0.01
        progressMessage = ""
        logText = ""
        notes = []
        startedAt = Date()
        take = 1; takes = 1; planning = false
        if job == .song && settings.livePlayback && settings.generator == "yue2" { player.beginLive() }

        runner = Task { @MainActor in
            // 1. Cover mode: transcribe the reference first when there's no score yet.
            let wantsTranscription = settings.hasReference
                && (job == .transcribeOnly || (job == .song && !settings.hasScore))
            if wantsTranscription {
                guard let abc = await transcribe(settings: settings) else { return finishFailed() }
                settings.customABC = abc
                settings.scoreSource = "transcription:" + settings.referenceAudio
                if job == .transcribeOnly { return finishOK() }
            }
            if job == .scoreOnly {
                guard let abc = await planScore(settings: settings, engineRoot: engineRoot, modelDir: modelDir) else {
                    return finishFailed()
                }
                settings.customABC = abc
                settings.scoreSource = "plan"
                return finishOK()
            }
            if job == .song && settings.generator == "levo2" {
                guard let song = await renderLeVo(settings: settings) else { return finishFailed() }
                lastSong = song
                return finishOK()
            }
            if job == .song {
                guard let song = await renderSong(settings: settings, engineRoot: engineRoot, modelDir: modelDir) else {
                    return finishFailed()
                }
                lastSong = song
                finishOK()
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        userCancelled = true
        phase = .cancelled
        process?.interrupt()
        process?.terminate()
    }

    private func finishOK() {
        phase = .finished
        progress = 1
        progressMessage = ""
    }

    private func finishFailed() {
        progress = nil
        if player.isLive { player.endLive() }
        if userCancelled {
            phase = .cancelled
            progressMessage = "Stopped."
        } else {
            phase = .failed
            progressMessage = failureReason
        }
    }

    // MARK: - Steps

    @MainActor
    private func transcribe(settings: SettingsStore) async -> String? {
        guard Tools.coverModeInstalled else {
            logText += "Cover Mode isn't installed. Open Settings → Install Cover Mode.\n"
            return nil
        }
        guard let ffmpeg = Tools.ffmpeg else {
            logText += "Cover Mode needs ffmpeg to read audio files, and none was found.\n"
            return nil
        }
        phase = .transcribing
        var source = settings.referenceAudio
        // Chords need the band, so only melody-only transcriptions use the isolated vocal.
        if settings.isolateVocals && !settings.coverChords && SideTasks.toolsInstalled {
            // A full mix confuses melody transcription; the isolated vocal is cleaner.
            progressMessage = "Isolating the vocal (Demucs)…"
            progress = nil
            if let v = await SideTasks.isolateVocals(URL(fileURLWithPath: source)), !userCancelled {
                source = v.path
                notes.append("Vocal isolated before transcription")
            } else if userCancelled {
                return nil
            } else {
                notes.append("Vocal isolation failed; transcribing the full mix")
            }
        }
        progressMessage = "Listening to the reference…"
        let name = URL(fileURLWithPath: settings.referenceAudio).deletingPathExtension().lastPathComponent
        let out = AppPaths.outputDir.appendingPathComponent("_transcriptions/\(name) \(UUID().uuidString.prefix(4))")
        var args = [Tools.transcribeScript, source,
                    "--models", Tools.sheetSageModels, "--output", out.path, "--ffmpeg", ffmpeg]
        if settings.coverChords { args.append("--with-chords") }
        let status = await stream(Tools.sheetSagePython, args)
        guard status == 0, let abc = try? String(contentsOf: out.appendingPathComponent("score.abc"), encoding: .utf8) else {
            return nil
        }
        lastTranscription = out
        notes.append("Transcribed \(name) → \(settings.coverChords ? "melody + chords" : "melody") score")
        return abc
    }

    @MainActor
    private func planScore(settings: SettingsStore, engineRoot: String, modelDir: String) async -> String? {
        phase = .planning
        planning = true
        let out = Tools.scratchDir.appendingPathComponent("plan-\(UUID().uuidString).abc")
        var args = [Tools.engineScript, "--scripts", engineRoot, "--model", modelDir, "plan",
                    "--style", settings.style, "--lyrics", settings.lyrics.isEmpty ? "[Verse]" : settings.lyrics,
                    "--cot", settings.planning == "off" ? "full" : settings.planning, "--out", out.path]
        args += planSampling(settings)
        if let seed = Int(settings.seed.trimmingCharacters(in: .whitespaces)) { args += ["--seed", String(seed)] }
        let status = await stream(AppPaths.pythonBin.path, args)
        defer { try? FileManager.default.removeItem(at: out) }
        guard status == 0 else { return nil }
        return try? String(contentsOf: out, encoding: .utf8)
    }

    @MainActor
    private func renderSong(settings: SettingsStore, engineRoot: String, modelDir: String) async -> SongEntry? {
        let fm = FileManager.default
        let folder = newSongFolder(style: settings.style)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var args = [Tools.engineScript, "--scripts", engineRoot, "--model", modelDir, "generate",
                    "--style", settings.style, "--lyrics", settings.lyrics,
                    "--cot", settings.planning,
                    "--steps", String(Int(settings.steps)),
                    "--cfg-scale", String(format: "%.2f", settings.cfgScale),
                    "--takes", String(Int(settings.takes)),
                    "--temperature", String(format: "%.3f", sampling(settings).temperature),
                    "--top-p", String(format: "%.3f", sampling(settings).topP),
                    "--top-k", String(Int(settings.topK)),
                    "--repetition-penalty", String(format: "%.3f", settings.repetitionPenalty),
                    "--keep-latents", "--out-dir", folder.path]
        args += planSampling(settings)
        if let seed = Int(settings.seed.trimmingCharacters(in: .whitespaces)) { args += ["--seed", String(seed)] }
        if settings.instrumental { args.append("--instrumental") }
        if settings.livePlayback {
            args.append("--live")
            if settings.liveKeep { args.append("--live-keep") }
        }
        if settings.autoLength { args.append("--auto-length") }
        args += ["--max-tokens", String(Int(min(settings.maxTokens, SettingsStore.tokenCap)))]
        expectedTokens = Int(settings.maxTokens)

        if settings.hasScore {
            // The score travels as a file, so quotes, bars and newlines need no escaping.
            let scoreFile = Tools.scratchDir.appendingPathComponent("input-\(UUID().uuidString).abc")
            try? fm.createDirectory(at: Tools.scratchDir, withIntermediateDirectories: true)
            try? settings.customABC.write(to: scoreFile, atomically: true, encoding: .utf8)
            args += ["--abc-file", scoreFile.path]
            if settings.tempoOverride { args += ["--tempo", String(Int(settings.tempoBPM))] }
            if settings.stripChords { args.append("--strip-chords") }
            if settings.keepVoice != "both" { args += ["--keep-voice", settings.keepVoice] }
        }

        if settings.isCover, let f = SettingsStore.faithfulness[settings.coverFaithfulness] {
            notes.append(String(format: "Cover: sticking to the original (%@ — randomness %.1f)", settings.coverFaithfulness, f.temperature))
        }
        let status = await stream(AppPaths.pythonBin.path, args)
        guard status == 0, let song = SongEntry.load(folder) else {
            // Keep any finished takes; drop a folder that holds nothing playable.
            let wavs = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".wav") } ?? []
            if wavs.isEmpty { try? fm.removeItem(at: folder) }
            return nil
        }
        if let t = lastTranscription, settings.hasReference {
            // Keep the cover's source transcription (MIDI, chords, beats) with the song.
            try? fm.copyItem(at: t, to: folder.appendingPathComponent("transcription"))
        }
        if settings.scoreSource.hasPrefix("transcription:"), SideTasks.toolsInstalled, !userCancelled {
            await measureMelodyMatch(song: song, reference: settings.customABC)
        }
        return SongEntry.load(folder) ?? song
    }

    /// LeVo 2: lyrics + style only (no scores, covers or live playback).
    @MainActor
    private func renderLeVo(settings: SettingsStore) async -> SongEntry? {
        guard Tools.levo2Installed else {
            logText += "LeVo 2 isn't installed. Run scripts/setup_levo2.sh from the project folder.\n"
            return nil
        }
        let fm = FileManager.default
        let folder = newSongFolder(style: settings.style)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var args = [Tools.engineDir.appendingPathComponent("levo2_engine.py").path,
                    "--levo-dir", Tools.levo2Dir.path, "--style", settings.style,
                    "--lyrics", settings.lyrics, "--seconds", String(Int(settings.maxTokens / 25)),
                    "--takes", String(Int(settings.takes)), "--out-dir", folder.path]
        if settings.instrumental { args.append("--instrumental") }
        if let seed = Int(settings.seed.trimmingCharacters(in: .whitespaces)) { args += ["--seed", String(seed)] }
        expectedTokens = Int(settings.maxTokens / 25 * 100 / 3)
        notes.append("LeVo 2 writes from your lyrics and style; scores and covers are YuE2 features")
        let status = await stream(AppPaths.pythonBin.path, args)
        guard status == 0, let song = SongEntry.load(folder) else {
            let wavs = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".wav") } ?? []
            if wavs.isEmpty { try? fm.removeItem(at: folder) }
            return nil
        }
        return song
    }

    /// Transcribe each take and score how closely its melody follows the reference.
    @MainActor
    private func measureMelodyMatch(song: SongEntry, reference: String) async {
        let fm = FileManager.default
        let ref = song.folder.appendingPathComponent("reference.abc")
        try? reference.write(to: ref, atomically: true, encoding: .utf8)
        var results: [String: [String: Double]] = [:]
        for (i, take) in song.takes.enumerated() {
            if userCancelled { return }
            phase = .decoding
            progress = nil
            progressMessage = "Checking how closely take \(i + 1) follows the reference melody…"
            let tx = song.folder.appendingPathComponent("match-\(take.file)")
            let t = await runCapture(Tools.sheetSagePython, [Tools.transcribeScript, song.takeURL(take).path,
                                                              "--models", Tools.sheetSageModels, "--output", tx.path,
                                                              "--ffmpeg", Tools.ffmpeg ?? "ffmpeg"])
            guard t.status == 0 else { continue }
            let m = await runCapture(AppPaths.pythonBin.path, [Tools.engineDir.appendingPathComponent("melody_match.py").path,
                                                                ref.path, tx.appendingPathComponent("score.abc").path])
            if let data = m.out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
                results[take.file] = obj
            }
            try? fm.removeItem(at: tx)
        }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: song.folder.appendingPathComponent("melody-match.json"))
        }
        if let best = results.max(by: { ($0.value["coverage"] ?? 0) * ($0.value["match"] ?? 0) < ($1.value["coverage"] ?? 0) * ($1.value["match"] ?? 0) }) {
            notes.append(String(format: "Melody match: best is %@ — reference melody present in %.0f%% of it", best.key, (best.value["coverage"] ?? 0) * 100))
        }
    }

    /// Covers use the "Stick to the original" setting; everything else the Advanced sliders.
    private func sampling(_ s: SettingsStore) -> (temperature: Double, topP: Double) {
        guard s.isCover || (s.hasReference && !s.hasScore),
              let f = SettingsStore.faithfulness[s.coverFaithfulness] else { return (s.temperature, s.topP) }
        return f
    }

    private func planSampling(_ s: SettingsStore) -> [String] {
        ["--plan-temperature", String(format: "%.3f", s.planTemperature),
         "--plan-top-p", String(format: "%.3f", s.planTopP),
         "--plan-top-k", String(Int(s.planTopK))]
    }

    // MARK: - Process plumbing

    /// Run one step, feeding complete stderr lines to `parse`. Returns the exit status.
    @MainActor
    private func stream(_ executable: String, _ args: [String]) async -> Int32 {
        guard FileManager.default.fileExists(atPath: executable) else {
            logText += "Missing \(executable). Run Setup from Settings.\n"
            return -1
        }
        if userCancelled { return -1 }
        logText += "» " + ([executable] + args).map(shellQuote).joined(separator: " ") + "\n"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args            // passed directly, never through a shell
        p.currentDirectoryURL = Tools.engineDir
        p.environment = Tools.pythonEnvironment()
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        process = p

        let splitter = LineSplitter()
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let lines = splitter.feed(chunk)
            if !lines.isEmpty {
                Task { @MainActor [weak self] in lines.forEach { self?.parse(line: $0) } }
            }
        }

        let status: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch {
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: -1)
            }
        }
        // Let the last queued lines land before callers inspect state.
        await Task.yield()
        process = nil
        return status
    }

    // MARK: - Parsing

    @MainActor
    private func parse(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !userCancelled else { return }

        if line.hasPrefix("[transcribe]") {
            phase = .transcribing
            progress = nil
            if let m = match("window (\\d+)/(\\d+)", line), let i = Double(m[1]), let n = Double(m[2]), n > 0 {
                progress = i / n
                progressMessage = "Transcribing the melody · section \(Int(i)) of \(Int(n))"
            } else {
                progressMessage = String(line.dropFirst("[transcribe] ".count)).capitalizingFirst
            }
        } else if line.hasPrefix("[plan]") {
            phase = .planning
            planning = true
            progress = nil
            progressMessage = "Writing the score (melody\(line.contains("ABC") ? " and chords" : ""))…"
        } else if line.hasPrefix("[abc]") {
            phase = .planning
            if let m = match("\\[abc\\] (\\d+) tokens, ([0-9.]+) tok/s", line) {
                progressMessage = "Writing the score · \(m[1]) symbols · \(m[2])/s"
            }
        } else if line.hasPrefix("[note]") {
            let text = String(line.dropFirst("[note] ".count))
            notes.append(text)
            if let m = match("-> (\\d+) tokens", text), let n = Int(m[1]) { expectedTokens = n }
        } else if line.hasPrefix("[take]") {
            if let m = match("\\[take\\] (\\d+)/(\\d+)", line), let i = Int(m[1]), let n = Int(m[2]) {
                take = i; takes = n
            }
        } else if line.hasPrefix("[live] ") {
            // "[live] <path> <start> <end>" — a playable section is ready.
            if let m = match("^\\[live\\] (.+\\.wav) ([0-9.]+) ([0-9.]+)$", line) {
                player.append(URL(fileURLWithPath: m[1]))
            } else if line == "[live] done" {
                player.endLive()
                progressMessage = "All sections streamed · rendering the final version" + takeSuffix
            }
        } else if line.hasPrefix("[semantic] prefix") {
            phase = .ar
            setProgress(0.02)
            progressMessage = "Composing" + takeSuffix
        } else if line.hasPrefix("[semantic]") {
            phase = .ar
            if let m = match("\\[semantic\\] (\\d+) tokens, ([0-9.]+) tok/s", line), let n = Double(m[1]) {
                setProgress(0.45 * min(1, n / Double(max(expectedTokens, 1))))
                let seconds = Int(n) / 25
                progressMessage = String(format: "Composing · %d:%02d of music so far · %@ tok/s", seconds / 60, seconds % 60, m[2]) + takeSuffix
            } else if line.contains("hit max_tokens") {
                notes.append("Take \(take) reached the length limit; the ending may be cut.")
            }
        } else if line.hasPrefix("[nar]") {
            phase = .nar
            if let m = match("step (\\d+)/(\\d+)", line), let i = Double(m[1]), let n = Double(m[2]), n > 0 {
                setProgress(0.45 + 0.45 * i / n)
                progressMessage = "Refining the sound · step \(Int(i)) of \(Int(n))" + takeSuffix
            }
        } else if line.hasPrefix("[vae]") {
            phase = .decoding
            setProgress(0.92)
            progressMessage = "Rendering the audio" + takeSuffix
        } else if line.hasPrefix("[done]") {
            if !planning || phase != .planning { setProgress(1) }
        } else if line.hasPrefix("[result]") {
            // Parsed from song.json instead; nothing to do.
        } else if !line.hasPrefix("[") {
            logText += line + "\n"
        }
    }

    private var takeSuffix: String { takes > 1 ? " · take \(take) of \(takes)" : "" }

    @MainActor
    private func setProgress(_ withinTake: Double) {
        progress = (Double(take - 1) + withinTake) / Double(max(takes, 1))
    }

    private func shellQuote(_ s: String) -> String {
        s.range(of: "[^A-Za-z0-9_./=:-]", options: .regularExpression) == nil
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// Collects bytes from a pipe and hands back only complete lines.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
