//
//  StemSession.swift — the Stem Remix workflow:
//    song → UVR5 split (BS-RoFormer vocals, then Demucs-ft on the instrumental)
//         → restyle chosen stems / regenerate a region / add a new layer (Stable Audio 3)
//         → mix in sync → export the mix or DAW-ready stems.
//  Every stem is 48 kHz and the song's exact length, so versions swap in place and
//  exported stems line up at bar 1 in Logic or Ableton.
//

import AppKit
import Foundation

struct StemTrack: Identifiable, Equatable {
    let name: String                 // "vocals", "drums", "layer 1"…
    var versions: [URL]              // [original, restyled 1, …]
    var labels: [String]
    var selected = 0
    var gain: Double = 1
    var muted = false
    var solo = false
    var restyle = false
    var id: String { name }
    var current: URL { versions[selected] }
}

extension Tools {
    static var separatorPython: String { AppPaths.baseDir.appendingPathComponent("Separator/venv/bin/python").path }
    static var separatorModels: String { AppPaths.baseDir.appendingPathComponent("Separator/models").path }
    static var separatorInstalled: Bool { FileManager.default.fileExists(atPath: separatorPython) }
    static var sa3Python: String { AppPaths.baseDir.appendingPathComponent("StableAudio3/venv/bin/python").path }
    static var sa3Installed: Bool { FileManager.default.fileExists(atPath: sa3Python) }
    /// Weights are gated; this only says whether a download has happened (HF cache has the repo).
    static var sa3WeightsPresent: Bool {
        let hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        return FileManager.default.fileExists(atPath: hub.appendingPathComponent("models--stabilityai--stable-audio-3-small-music").path)
    }
}

/// Stream a helper's stderr line by line (progress) and return its exit status and last lines.
func streamProcess(_ executable: String, _ args: [String], onLine: @escaping (String) -> Void) async -> (Int32, [String]) {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = Tools.pythonEnvironment()
        env.removeValue(forKey: "HF_HUB_OFFLINE")   // Stable Audio 3 checks its cache online-first
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        final class Tail: @unchecked Sendable { var lines: [String] = []; var buf = Data(); let lock = NSLock() }
        let tail = Tail()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            tail.lock.lock()
            tail.buf.append(d)
            var out: [String] = []
            while let nl = tail.buf.firstIndex(of: 0x0A) {
                out.append(String(decoding: tail.buf[tail.buf.startIndex..<nl], as: UTF8.self))
                tail.buf.removeSubrange(tail.buf.startIndex...nl)
            }
            tail.lines = Array((tail.lines + out).suffix(30))
            tail.lock.unlock()
            for l in out { DispatchQueue.main.async { onLine(l) } }
        }
        p.terminationHandler = { proc in
            err.fileHandleForReading.readabilityHandler = nil
            tail.lock.lock(); let lines = tail.lines; tail.lock.unlock()
            cont.resume(returning: (proc.terminationStatus, lines))
        }
        do { try p.run() } catch { cont.resume(returning: (-1, [error.localizedDescription])) }
    }
}

final class StemSession: ObservableObject {
    @Published var source: URL?
    @Published private(set) var folder: URL?
    @Published var tracks: [StemTrack] = []
    @Published private(set) var busy: String?
    @Published var message: String?

    // Split options
    @Published var vocalModel = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
    @Published var bandModel = "htdemucs_ft.yaml"
    // Stable Audio 3 options
    @Published var prompt = ""
    @Published var strength = 0.6
    @Published var bpm: Double = 0
    @Published var sa3Model = "small-music"
    // Region / layer
    @Published var regionTrack = ""
    @Published var regionStart: Double = 0
    @Published var regionEnd: Double = 8
    @Published var regionPrompt = ""
    @Published var layerPrompt = ""

    let mixer = StemMixer()

    static let vocalModels = [
        ("model_bs_roformer_ep_317_sdr_12.9755.ckpt", "BS-RoFormer (cleanest instrumental)"),
        ("vocals_mel_band_roformer.ckpt", "MelBand-RoFormer Kim (cleanest vocals)"),
    ]
    static let bandModels = [
        ("htdemucs_ft.yaml", "Demucs v4 fine-tuned: drums, bass, other"),
        ("htdemucs_6s.yaml", "Demucs v4 6-stem: + guitar, piano"),
    ]

    var songSeconds: Double { mixer.duration }

    // MARK: Source

    func open(_ url: URL, bpmHint: Double? = nil) {
        mixer.removeAll()
        tracks = []
        source = url
        message = nil
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
        folder = AppPaths.outputDir.appendingPathComponent("_remix/\(f.string(from: Date())) \(url.deletingPathExtension().lastPathComponent)")
        bpm = bpmHint ?? 0
        if bpmHint == nil { Task { await self.guessBPM(from: url) } }
    }

    /// A take from a song folder carries its score's tempo.
    @MainActor private func guessBPM(from url: URL) async {
        let score = url.deletingLastPathComponent().appendingPathComponent("score.abc")
        if let text = try? String(contentsOf: score), let c = await checkScore(text), let b = c.bpm { bpm = Double(b) }
    }

    // MARK: Split

    @MainActor
    func split() async {
        guard let source, let folder else { return }
        guard Tools.separatorInstalled else { message = "Install stem separation first (Settings)."; return }
        let out = folder.appendingPathComponent("stems")
        busy = "Splitting: vocals first…"
        let (status, tail) = await streamProcess(Tools.separatorPython, [
            Tools.engineDir.appendingPathComponent("stems.py").path, source.path, "--out", out.path,
            "--models", Tools.separatorModels, "--ffmpeg", Tools.ffmpeg ?? "ffmpeg",
            "--vocal-model", vocalModel, "--band-model", bandModel]) { [weak self] line in
            if line.contains("pass 2") { self?.busy = "Splitting: drums, bass and the rest…" }
        }
        busy = nil
        guard status == 0 else { message = tail.last(where: { !$0.hasPrefix("[") }) ?? "Separation failed."; return }
        let order = ["vocals", "drums", "bass", "guitar", "piano", "other"]
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [])
            .filter { $0.hasSuffix(".wav") && $0 != "instrumental.wav" }
            .sorted { (order.firstIndex(of: $0.replacingOccurrences(of: ".wav", with: "")) ?? 9) <
                      (order.firstIndex(of: $1.replacingOccurrences(of: ".wav", with: "")) ?? 9) }
        tracks = files.map { f in
            let name = f.replacingOccurrences(of: ".wav", with: "")
            return StemTrack(name: name, versions: [out.appendingPathComponent(f)], labels: ["Original"],
                             restyle: name == "other")
        }
        for t in tracks { mixer.set(t.name, url: t.current) }
        regionTrack = tracks.first(where: { $0.name == "other" })?.name ?? tracks.first?.name ?? ""
        message = "Split into \(tracks.count) stems. Tick the ones to restyle."
    }

    // MARK: Stable Audio 3

    private func remix(_ args: [String], label: String) async -> (URL?, String?) {
        guard Tools.sa3Installed else { return (nil, "Install Remix (Stable Audio 3) first — see Settings.") }
        var full = [Tools.engineDir.appendingPathComponent("remix.py").path] + args
        full += ["--model", sa3Model, "--ffmpeg", Tools.ffmpeg ?? "ffmpeg"]
        let (status, tail) = await streamProcess(Tools.sa3Python, full) { [weak self] line in
            if line.hasPrefix("[remix]") { self?.busy = label + " · " + line.dropFirst(8) }
        }
        guard status == 0 else {
            return (nil, tail.last(where: { !$0.hasPrefix("[") && !$0.contains("flash_attn") && !$0.isEmpty }) ?? "Stable Audio 3 failed.")
        }
        let file = tail.compactMap { l -> String? in
            guard l.hasPrefix("[result] "), let d = l.dropFirst(9).data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o["file"] as? String
        }.last
        return (file.map { URL(fileURLWithPath: $0) }, nil)
    }

    @MainActor
    func restyleTicked() async {
        guard let folder else { return }
        let targets = tracks.filter(\.restyle)
        guard !targets.isEmpty else { message = "Tick at least one stem to restyle."; return }
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { message = "Describe the new sound first."; return }
        for t in targets {
            busy = "Restyling \(t.name)…"
            let n = t.versions.count
            let out = folder.appendingPathComponent("restyled/\(t.name)-\(n).wav")
            var args = ["restyle", t.versions[0].path, "--prompt", prompt, "--strength", String(format: "%.2f", strength),
                        "--out", out.path]
            if bpm > 0 { args += ["--bpm", String(format: "%.2f", bpm)] }
            let (file, err) = await remix(args, label: "Restyling \(t.name)")
            if let err { busy = nil; message = err; return }
            if let file, let i = tracks.firstIndex(where: { $0.name == t.name }) {
                tracks[i].versions.append(file)
                tracks[i].labels.append("Restyled \(n) — \(prompt.prefix(24))")
                tracks[i].selected = tracks[i].versions.count - 1
                mixer.set(t.name, url: file, gain: Float(tracks[i].gain))
            }
        }
        busy = nil
        message = "Restyled \(targets.count) stem\(targets.count == 1 ? "" : "s"). Switch versions on each row to compare."
    }

    @MainActor
    func regenerateRegion() async {
        guard let folder, let i = tracks.firstIndex(where: { $0.name == regionTrack }) else { return }
        guard regionEnd > regionStart else { message = "The region must end after it starts."; return }
        let t = tracks[i]
        busy = "Regenerating \(t.name) \(clock(regionStart))–\(clock(regionEnd))…"
        let out = folder.appendingPathComponent("restyled/\(t.name)-region-\(t.versions.count).wav")
        let (file, err) = await remix(["region", t.current.path, "--start", String(regionStart), "--end", String(regionEnd),
                                        "--prompt", regionPrompt.isEmpty ? prompt : regionPrompt, "--out", out.path],
                                       label: "Regenerating \(t.name)")
        busy = nil
        if let err { message = err; return }
        if let file {
            tracks[i].versions.append(file)
            tracks[i].labels.append("Region \(clock(regionStart))–\(clock(regionEnd))")
            tracks[i].selected = tracks[i].versions.count - 1
            mixer.set(t.name, url: file, gain: Float(tracks[i].gain))
        }
    }

    @MainActor
    func addLayer() async {
        guard let folder, songSeconds > 0 else { return }
        guard !layerPrompt.trimmingCharacters(in: .whitespaces).isEmpty else { message = "Describe the new layer first."; return }
        let n = tracks.filter { $0.name.hasPrefix("layer") }.count + 1
        busy = "Creating layer \(n)…"
        let raw = folder.appendingPathComponent("restyled/layer-\(n)-raw.wav")
        let out = folder.appendingPathComponent("restyled/layer-\(n).wav")
        var p = layerPrompt
        if bpm > 0 && !p.lowercased().contains("bpm") { p += ", \(Int(bpm)) BPM" }
        let (file, err) = await remix(["create", "--prompt", p, "--seconds", String(format: "%.2f", min(songSeconds, 110)),
                                       "--out", raw.path], label: "Creating layer \(n)")
        busy = nil
        if let err { message = err; return }
        guard let file else { return }
        // Pad or trim to the song's exact length so it lines up with the other stems.
        if let ff = Tools.ffmpeg {
            _ = await runCapture(ff, ["-y", "-v", "error", "-i", file.path, "-af", "apad", "-t", String(format: "%.4f", songSeconds),
                                      "-ar", "48000", "-c:a", "pcm_s24le", out.path])
        }
        let url = FileManager.default.fileExists(atPath: out.path) ? out : file
        let name = "layer \(n)"
        tracks.append(StemTrack(name: name, versions: [url], labels: ["Created — \(layerPrompt.prefix(24))"]))
        mixer.set(name, url: url)
        if songSeconds > 110 { message = "Stable Audio 3 Small makes up to 2 minutes; the layer covers the start and is silent after." }
    }

    // MARK: Mix controls

    func select(_ name: String, version: Int) {
        guard let i = tracks.firstIndex(where: { $0.name == name }), tracks[i].versions.indices.contains(version) else { return }
        tracks[i].selected = version
        mixer.set(name, url: tracks[i].current, gain: Float(tracks[i].gain))
    }
    func setGain(_ name: String, _ g: Double) {
        guard let i = tracks.firstIndex(where: { $0.name == name }) else { return }
        tracks[i].gain = g; mixer.setGain(name, Float(g))
    }
    func toggleMute(_ name: String) {
        guard let i = tracks.firstIndex(where: { $0.name == name }) else { return }
        tracks[i].muted.toggle(); mixer.setMuted(name, tracks[i].muted)
    }
    func toggleSolo(_ name: String) {
        guard let i = tracks.firstIndex(where: { $0.name == name }) else { return }
        tracks[i].solo.toggle(); mixer.setSolo(name, tracks[i].solo)
    }

    // MARK: Export

    private var audible: [StemTrack] {
        let solos = tracks.filter(\.solo)
        return tracks.filter { !$0.muted && (solos.isEmpty || $0.solo) }
    }

    @MainActor
    func exportMix() async -> URL? {
        guard let folder, let ff = Tools.ffmpeg, !audible.isEmpty else { message = "Nothing to mix."; return nil }
        busy = "Mixing…"
        let out = folder.appendingPathComponent("mix.wav")
        var args = ["-y", "-v", "error"]
        for t in audible { args += ["-i", t.current.path] }
        let chains = audible.enumerated().map { i, t in "[\(i):a]volume=\(String(format: "%.4f", t.gain))[a\(i)]" }
        let inputs = (0..<audible.count).map { "[a\($0)]" }.joined()
        args += ["-filter_complex", chains.joined(separator: ";") + ";\(inputs)amix=inputs=\(audible.count):normalize=0[m]",
                 "-map", "[m]", "-ar", "48000", "-c:a", "pcm_s24le", out.path]
        let r = await runCapture(ff, args)
        busy = nil
        guard r.status == 0 else { message = "Mixing failed: \(r.err.prefix(200))"; return nil }
        message = "Mix saved."
        return out
    }

    @MainActor
    func exportStems() -> URL? {
        guard let folder else { return nil }
        let dir = folder.appendingPathComponent("stems for DAW")
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, t) in audible.enumerated() {
            let label = t.selected == 0 ? t.name : "\(t.name) (\(t.labels[t.selected].lowercased().prefix(20)))"
            try? fm.copyItem(at: t.current, to: dir.appendingPathComponent(String(format: "%02d %@.wav", i + 1, label)))
        }
        message = "Stems exported: 48 kHz, same length, all start at 0:00 — drop them in at bar 1."
        return dir
    }

    private func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}
