//
//  GeneratorView.swift — writing canvas on the left, card toolbox + actions on
//  the right, and a single friendly status/result panel at the bottom-left.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GeneratorView: View {
    @ObservedObject var setup: SetupManager
    @ObservedObject var engine: GenerationEngine
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var side = SideTasks()
    @State private var lyricsReport: LyricsReport?

    enum Canvas: String, CaseIterable, Identifiable {
        case lyrics = "Lyrics & Style", score = "Score", cover = "Cover / Hum"
        var id: String { rawValue }
    }

    @State private var canvas: Canvas = .lyrics
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showHistory = false
    @State private var showLog = false
    @State private var showAdvanced = false
    @State private var selectedTake: TakeRecord?
    @State private var exportMessage: String?

    private var theme: AppTheme { settings.theme }

    private var modelOptions: [String] {
        guard let root = settings.engineRoot else { return [] }
        return SetupManager.availableModels(engineRoot: root)
    }

    private var canGenerate: Bool {
        guard !engine.isRunning, !settings.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Instrumental songs need no words; everything else needs lyrics (section tags at least).
        return settings.instrumental || !settings.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            AmbientThemeBackground(theme: theme).ignoresSafeArea()

            GeometryReader { g in
                HStack(alignment: .top, spacing: 0) {
                    leftPanel
                        .frame(width: g.size.width * 0.64, height: g.size.height)
                    Divider().opacity(0.6)
                    rightPanel
                        .frame(width: g.size.width * 0.36, height: g.size.height)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("History — every song, take and score")
                themeMenu
                Button { showAbout.toggle() } label: { Image(systemName: "info.circle") }
                    .help("About YuE2Mac")
                    .popover(isPresented: $showAbout) { aboutContent }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Engine setup and Cover Mode")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(setup: setup) }
        .sheet(isPresented: $showHistory) {
            HistorySheet(settings: settings) { scoreURL in reuseScore(scoreURL) }
        }
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(item: Binding(get: { lyricsReport.map(LyricsReportBox.init) }, set: { lyricsReport = $0?.report })) { box in
            LyricsReportSheet(report: box.report)
        }
        .onChange(of: engine.lastSong) { song in selectedTake = song?.takes.first }
        .onChange(of: engine.phase) { phase in
            // A finished score-only job or transcription lands in the Score tab for review.
            if phase == .finished, engine.lastJob != .song { canvas = .score }
        }
    }

    // MARK: - Left: writing canvas

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $canvas) {
                ForEach(Canvas.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.segmented).labelsHidden()

            TopCard {
                Group {
                    switch canvas {
                    case .lyrics:
                        VStack(alignment: .leading, spacing: 12) {
                            styleField
                            Divider()
                            tagsRow
                            lyricsEditor
                        }
                    case .score:
                        ScrollView {
                            ScoreCanvas(settings: settings, engine: engine, side: side, theme: theme, writeScore: { start(.scoreOnly) })
                                .padding(.trailing, 8)
                        }
                    case .cover:
                        ScrollView {
                            CoverCanvas(settings: settings, engine: engine, theme: theme,
                                        transcribe: { start(.transcribeOnly) }, showScore: { canvas = .score })
                                .padding(.trailing, 8)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)

            resultPanel
        }
        .padding(20)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("YuE2Mac").font(.system(.title, design: .rounded, weight: .bold))
                Text(modelSummary).font(.system(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if settings.hasScore || settings.hasReference {
                Text(inputSummary)
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.accentColor.opacity(0.18), in: Capsule())
                    .help("What Generate will use besides your style and lyrics")
            }
        }
    }

    private var inputSummary: String {
        if settings.hasScore { return "Using your score" + (settings.tempoOverride ? " at \(Int(settings.tempoBPM)) BPM" : "") }
        return "Cover of \(URL(fileURLWithPath: settings.referenceAudio).lastPathComponent)"
    }

    private var modelSummary: String {
        let name = settings.modelDir.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "no model"
        return "\(SystemInfo.chipName) · \(name) · 48 kHz stereo"
    }

    private var styleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Style prompt", systemImage: "slider.horizontal.3")
                    .font(.system(.body, weight: .semibold))
                Spacer()
                HelpButton(text: "Genre, instruments, vocal character, language and tempo (e.g. \"96 BPM\"). With a score or a cover, this is what restyles the melody.")
                Button { shuffleStyle() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .foregroundStyle(theme.accentColor)
                    .help("Use a different starter style")
            }
            TextField("English, indie pop, bright acoustic guitar, soft drums, warm female vocal, 96 BPM…",
                      text: $settings.style, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .lineLimit(1...3)
                .padding(10)
                .background(fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(fieldBorder, lineWidth: 1))
        }
    }

    private var tagsRow: some View {
        HStack(spacing: 6) {
            ForEach(["Intro", "Verse", "Pre-Chorus", "Chorus", "Bridge", "Outro", "Instrumental"], id: \.self) { tag in
                Button("[\(tag)]") { insertTag(tag) }
                    .buttonStyle(.borderless).controlSize(.small).foregroundStyle(theme.accentColor)
            }
            Spacer()
            Menu {
                ForEach(Presets.lyrics, id: \.name) { set in
                    Button(set.name) { settings.lyrics = set.text }
                }
            } label: {
                Label("Samples", systemImage: "text.book.closed")
            }
            .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            .help("Load a ready-made set of lyrics")

            Toggle(isOn: $settings.instrumental) {
                HStack(spacing: 4) { Text("Instrumental"); HelpButton(text: "No singing. The score's vocal line is turned into rests before any audio is made (chords and the instrumental melody stay), and the lyrics are reduced to section tags.") }
            }
            .toggleStyle(.switch).controlSize(.mini)
        }
    }

    private var lyricsEditor: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $settings.lyrics)
                .font(.system(.body))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .background(fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(fieldBorder, lineWidth: 1))
                .opacity(settings.instrumental ? 0.5 : 1)
            Text(settings.instrumental ? "Instrumental — only [section] tags are used" : "\(settings.lyrics.count) characters")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary).padding(.trailing, 14).padding(.bottom, 8)
        }
    }

    /// Status while working; player, takes and actions once a song is ready.
    private var resultPanel: some View {
        TopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        Circle().fill(theme.accentColor.opacity(0.15)).frame(width: 28, height: 28)
                        resultIcon.font(.system(size: 13, weight: .semibold))
                    }
                    Text(resultTitle).font(.system(.title3))
                    Spacer()
                    if engine.isRunning, let start = engine.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(elapsed(from: start, to: ctx.date)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    if !engine.logText.isEmpty {
                        Button { showLog = true } label: { Image(systemName: "text.alignleft") }
                            .buttonStyle(.borderless).help("Show the engine log")
                    }
                }

                if engine.isRunning {
                    Text(processingText).font(.system(.body))
                    if let p = engine.progress {
                        ProgressView(value: p).progressViewStyle(.linear).tint(theme.accentColor)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(theme.accentColor)
                    }
                    if !engine.detailLine.isEmpty {
                        Text(engine.detailLine).font(.system(.footnote, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                } else if engine.phase == .finished, engine.lastJob == .song, let song = engine.lastSong {
                    songResult(song)
                } else if engine.phase == .failed {
                    Text(engine.failureReason).font(.system(.callout, design: .monospaced)).foregroundStyle(.orange).lineLimit(3)
                } else if engine.phase == .finished {
                    Text(engine.lastJob == .scoreOnly ? "Score written — it's in the Score tab. Check or edit it, then Generate." :
                         "Transcribed — the score is in the Score tab. Check it, then Generate.")
                        .foregroundStyle(.secondary)
                } else {
                    idleText
                }
                ForEach(engine.notes.suffix(2), id: \.self) { n in
                    Text("• " + n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(height: 186)
    }

    @ViewBuilder
    private func songResult(_ song: SongEntry) -> some View {
        let take = selectedTake ?? song.takes.first
        if let take {
            HStack(spacing: 10) {
                if song.takes.count > 1 {
                    Picker("", selection: Binding(get: { take }, set: { selectedTake = $0 })) {
                        ForEach(Array(song.takes.enumerated()), id: \.element) { i, t in Text("Take \(i + 1)").tag(t) }
                    }
                    .labelsHidden().fixedSize()
                }
                AudioPlayer(url: song.takeURL(take)).id(song.takeURL(take))
            }
            HStack(spacing: 8) {
                Button { reuseScore(song.scoreURL, autoGenerate: true) } label: { Label("New take, same song", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!song.hasScore)
                    .help("Keep this exact score (notes and chords) and perform it again with a new seed")
                Button { reuseScore(song.scoreURL) } label: { Label("Edit score", systemImage: "square.and.pencil") }
                    .disabled(!song.hasScore)
                Menu {
                    Toggle("Master to streaming loudness (−14 LUFS)", isOn: $settings.masterLoudness)
                    Divider()
                    ForEach(ExportFormat.allCases) { f in
                        Button(f.title) { export(song.takeURL(take), f) }
                    }
                    Divider()
                    Button("Split into stems (vocals, drums, bass, other)") {
                        Task {
                            if let dir = await side.stems(of: song.takeURL(take)) { NSWorkspace.shared.open(dir) }
                        }
                    }
                    .disabled(side.busy != nil)
                    if FileManager.default.fileExists(atPath: song.folder.appendingPathComponent("transcription").path) {
                        Divider()
                        Button("Transcription MIDI files") {
                            NSWorkspace.shared.open(song.folder.appendingPathComponent("transcription"))
                        }
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
                Button { checkLyrics(song, take) } label: { Label("Check lyrics", systemImage: "text.badge.checkmark") }
                    .disabled(side.busy != nil || songIsInstrumental(song))
                    .help("Transcribe what was actually sung and compare it with your lyrics")
                Button { NSWorkspace.shared.activateFileViewerSelecting([song.takeURL(take)]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                Spacer()
                if take.semantic_truncated {
                    Label("Hit length limit", systemImage: "scissors").font(.caption).foregroundStyle(.orange)
                        .help("Raise Max length or turn on Fit to score")
                }
            }
            .controlSize(.small)
            if let busy = side.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(.secondary) }
            } else if let m = side.message ?? exportMessage {
                Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func elapsed(from a: Date, to b: Date) -> String {
        let s = max(0, Int(b.timeIntervalSince(a)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private let idleText = Text("Write lyrics and a style, or bring a score or a recording. Then press **Generate Song** — it all runs on this Mac.")

    @ViewBuilder
    private var resultIcon: some View {
        switch engine.phase {
        case .preparing, .transcribing, .planning, .ar, .nar, .decoding, .writing: Image(systemName: "waveform").foregroundStyle(theme.accentColor)
        case .finished: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed, .cancelled: Image(systemName: "xmark").foregroundStyle(.red)
        default: Image(systemName: "sparkles").foregroundStyle(theme.accentColor)
        }
    }

    private var resultTitle: String {
        switch engine.phase {
        case .idle: return "Ready"
        case .finished:
            switch engine.lastJob {
            case .song: return (engine.lastSong?.takes.count ?? 1) > 1 ? "Your takes are ready" : "Your song is ready"
            case .scoreOnly: return "Score ready"
            case .transcribeOnly: return "Transcription ready"
            }
        case .failed: return "Something went wrong"
        case .cancelled: return "Stopped"
        default: return engine.lastJob == .song ? "Making your song" : "Working"
        }
    }

    private var processingText: String {
        switch engine.phase {
        case .preparing:    return "Loading the model…"
        case .transcribing: return "Transcribing the reference melody (SheetSage2)…"
        case .planning:     return "Writing the score…"
        case .ar:           return "Composing the performance…"
        case .nar:          return "Refining the sound…"
        case .decoding:     return "Rendering the audio…"
        case .writing:      return "Saving…"
        default:            return "Working…"
        }
    }

    // MARK: - Right: toolbox & actions

    private var rightPanel: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    modelCard
                    qualityCard
                    lengthCard
                    advancedCard
                }
                .padding(16)
            }
            actionButtons.padding([.horizontal, .bottom], 16)
        }
    }

    private var modelCard: some View {
        SectionCard(theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Model & Mode", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(.body, weight: .semibold))
                alignRow(title: "Model", help: "Which weights to generate with. bf16 is the full, unquantized model.") {
                    Picker("", selection: Binding(
                        get: { settings.modelDir ?? "" },
                        set: { settings.modelDir = $0 }
                    )) {
                        ForEach(modelOptions, id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                alignRow(title: "Mode", help: "Auto: Text-to-Song when there's no score; with a score, Harmonic Blueprint if it has chords, Strict Melody if not.\n\nText-to-Song (full): YuE2 writes melody + chords, then performs them.\nMelody plan: YuE2 writes a melody only; accompaniment is free.\nNo plan (off): straight to audio — fastest, least structured.\n\nWith a score: full locks the chords, melody locks only the melody.") {
                    Picker("", selection: $settings.planning) {
                        Text("Auto").tag("auto")
                        Text("Text-to-Song / Harmonic Blueprint (full)").tag("full")
                        Text("Melody plan / Strict Melody (melody)").tag("melody")
                        Text("No plan — fastest (off)").tag("off")
                    }
                    .labelsHidden().fixedSize()
                }
                if settings.planning == "off" && settings.hasScore {
                    Text("A score needs a planning mode; Auto will be used for it.").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
    }

    private var qualityCard: some View {
        SectionCard(theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Quality", systemImage: "waveform.path").font(.system(.body, weight: .semibold))
                    Spacer()
                    Button("Draft") { settings.applyDraft() }
                        .help("Fast previews: 12 refinement steps, no extra guidance pass")
                    Button("Final") { settings.applyFinal() }
                        .help("The model's reference quality: 32 steps, guidance 1.0")
                }
                .controlSize(.small)
                labeledSlider("Refinement steps", $settings.steps, 4...64, whole: true, theme: theme,
                              help: "Flow-matching steps that turn the composition into sound. 32 is the model's standard; fewer is faster and rougher.")
                labeledSlider("CFG — style obedience", $settings.cfgScale, 1...5, whole: false, theme: theme, step: 0.05,
                              help: "1.0 is the model's default. Above 1 follows the style prompt harder but runs a second pass (about 1.5× slower on the main stage) and may reduce quality.")
            }
            .padding(12)
        }
    }

    private var lengthCard: some View {
        SectionCard(theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Length & Takes", systemImage: "clock").font(.system(.body, weight: .semibold))
                Toggle(isOn: $settings.autoLength) {
                    HStack(spacing: 4) { Text("Fit length to the score"); HelpButton(text: "Sizes the limit to the score's own length so songs aren't cut off. Uses Max length when there's no score.") }
                }
                .toggleStyle(.switch).controlSize(.small)
                labeledSlider("Max length", $settings.maxTokens, 500...SettingsStore.tokenCap, whole: true, theme: theme, step: 250,
                              help: "Token ceiling: 25 per second of music. 9,000 (6 minutes) is the model's limit.")
                Text(lengthLabel).font(.caption).foregroundStyle(.secondary)
                alignRow(title: "Takes", help: "Several performances of the same song in one go. They share one score, each with its own seed.") {
                    Stepper(value: $settings.takes, in: 1...8) { Text("\(Int(settings.takes))").font(.system(.body, design: .monospaced)) }
                }
                alignRow(title: "Seed", help: "Same inputs + same seed = the same song. Blank = random. With several takes, seeds count up from here.") {
                    TextField("Random", text: $settings.seed)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(width: 110)
                }
            }
            .padding(12)
        }
    }

    private var lengthLabel: String {
        let s = Int(settings.maxTokens) / 25
        return String(format: "Up to %d:%02d", s / 60, s % 60) + (settings.autoLength ? " without a score" : "")
    }

    private var advancedCard: some View {
        SectionCard(theme: theme) {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Music (the performance)").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    labeledSlider("Temperature", $settings.temperature, 0.1...1.5, whole: false, theme: theme, step: 0.05,
                                  help: "Randomness. Lower is safer and more repetitive; higher is wilder. Model default 1.0.")
                    labeledSlider("Top-P", $settings.topP, 0.0...1.0, whole: false, theme: theme, step: 0.01,
                                  help: "Nucleus sampling: only the most likely choices adding up to this share are allowed. Model default 0.95.")
                    labeledSlider("Top-K", $settings.topK, 1...500, whole: true, theme: theme, step: 1,
                                  help: "At most this many candidates per step. Model default 100.")
                    labeledSlider("Repetition penalty", $settings.repetitionPenalty, 1.0...2.0, whole: false, theme: theme, step: 0.01,
                                  help: "Discourages repeating the last 50 sounds. Model default 1.2.")
                    Text("Score (the plan)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    labeledSlider("Plan temperature", $settings.planTemperature, 0.1...1.5, whole: false, theme: theme, step: 0.05,
                                  help: "Randomness when YuE2 writes the melody and chords. Model default 0.7.")
                    labeledSlider("Plan Top-P", $settings.planTopP, 0.0...1.0, whole: false, theme: theme, step: 0.01,
                                  help: "Model default 0.9.")
                    labeledSlider("Plan Top-K", $settings.planTopK, 1...200, whole: true, theme: theme, step: 1,
                                  help: "Model default 30.")
                    Button("Reset to model defaults") { settings.resetSampling() }.controlSize(.small)
                }
            } label: {
                Label("Advanced Audio Sliders", systemImage: "dial.medium").font(.system(.body, weight: .semibold))
            }
            .padding(12)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                if engine.isRunning { engine.cancel() } else { start(.song) }
            } label: {
                HStack {
                    if engine.isRunning {
                        Image(systemName: "stop.fill")
                        Text("Stop").fontWeight(.semibold)
                    } else {
                        Image(systemName: "sparkles")
                        Text(generateTitle).fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? Color.red : theme.accentColor)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!engine.isRunning && !canGenerate)
            .help(canGenerate || engine.isRunning ? "⌘↩" : "Add a style and lyrics (or turn on Instrumental)")
        }
    }

    private var generateTitle: String {
        let n = Int(settings.takes)
        let what = n > 1 ? "Generate \(n) Takes" : "Generate Song"
        if !settings.hasScore && settings.hasReference { return "Transcribe & " + what }
        return what
    }

    // MARK: - Toolbar extras

    private var themeMenu: some View {
        Menu {
            ForEach(AppTheme.allCases) { t in
                Button { settings.theme = t } label: {
                    if t == settings.theme { Label(t.displayName, systemImage: "checkmark") } else { Text(t.displayName) }
                }
            }
        } label: { Image(systemName: "paintpalette") }
        .help("Appearance")
    }

    private var aboutContent: some View {
        VStack(spacing: 12) {
            if let nsImage = NSImage(named: "AppIcon") {
                Image(nsImage: nsImage)
                    .resizable().frame(width: 64, height: 64).cornerRadius(14)
            } else {
                Image(systemName: "music.note.list").font(.system(size: 34, weight: .bold))
                    .foregroundStyle(theme.accentColor)
            }
            Text("YuE2Mac").font(.system(.title3, design: .rounded, weight: .bold))
            Text("Version \(appVersion)")
                .font(.system(.caption)).foregroundStyle(.secondary)
            Text("Model: YuE2-3B (MLX) · workstation build")
                .font(.system(.caption2)).foregroundStyle(.tertiary)

            Button(action: checkForUpdates) {
                Text(updateStatusText)
                    .font(.system(.caption))
                    .foregroundStyle(updateURL != nil ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(updateURL != nil ? theme.accentColor : Color.gray.opacity(0.25), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(updateStatusText == "Checking…" || updateStatusText == "Up to date")
        }
        .padding(20).frame(width: 240)
        .onAppear { if !didCheckUpdate { checkForUpdates() } }
    }

    @State private var updateStatusText = "Check for Updates"
    @State private var updateURL: URL?
    @State private var didCheckUpdate = false

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    private func checkForUpdates() {
        if let url = updateURL { NSWorkspace.shared.open(url); return }
        updateStatusText = "Checking…"
        didCheckUpdate = true
        Task {
            let releases = URL(string: "https://github.com/arinltte/YuE2Mac/releases/latest")!
            var req = URLRequest(url: releases); req.httpMethod = "HEAD"
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let tag = resp.url?.lastPathComponent.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "v")), !tag.isEmpty else {
                await MainActor.run { updateStatusText = "Check for Updates" }; return
            }
            let newer = tag.compare(appVersion, options: .numeric) == .orderedDescending
            await MainActor.run {
                if newer {
                    updateStatusText = "New version available"
                    updateURL = URL(string: "https://github.com/arinltte/YuE2Mac/releases")
                } else {
                    updateStatusText = "Up to date"
                }
            }
        }
    }

    // MARK: - Actions & helpers

    private func shuffleStyle() {
        guard !Presets.styles.isEmpty else { return }
        if let idx = Presets.styles.firstIndex(of: settings.style) {
            settings.style = Presets.styles[(idx + 1) % Presets.styles.count]
        } else {
            settings.style = Presets.styles[0]
        }
    }

    private func insertTag(_ tag: String) {
        settings.lyrics += (settings.lyrics.isEmpty ? "" : "\n") + "[\(tag)]\n"
    }

    private func start(_ job: GenerationEngine.Job) {
        guard let root = settings.engineRoot, let model = settings.modelDir else { return }
        exportMessage = nil
        engine.run(job, settings: settings, engineRoot: root, modelDir: model)
    }

    /// Put a finished song's score back in the Score tab; optionally render new takes of it right away.
    private func reuseScore(_ url: URL, autoGenerate: Bool = false) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        settings.customABC = text
        settings.tempoOverride = false
        settings.stripChords = false
        settings.keepVoice = "both"
        settings.seed = ""
        canvas = .score
        if autoGenerate { start(.song) }
    }

    private func songIsInstrumental(_ song: SongEntry) -> Bool {
        guard let data = try? Data(contentsOf: song.folder.appendingPathComponent("song.json")),
              let rec = try? JSONDecoder().decode(SongRecord.self, from: data) else { return false }
        return rec.request.instrumental == true
    }

    private func checkLyrics(_ song: SongEntry, _ take: TakeRecord) {
        guard let data = try? Data(contentsOf: song.folder.appendingPathComponent("song.json")),
              let rec = try? JSONDecoder().decode(SongRecord.self, from: data) else { return }
        Task {
            if let r = await side.lyricsCheck(take: song.takeURL(take), lyrics: rec.request.lyrics) {
                lyricsReport = r
            }
        }
    }

    private func export(_ take: URL, _ format: ExportFormat) {
        exportMessage = "Exporting…"
        let master = settings.masterLoudness
        Task {
            let r = await Exporter.export(take, as: format, master: master)
            await MainActor.run {
                switch r {
                case .success(let url):
                    exportMessage = "Saved \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let e):
                    exportMessage = e.message
                }
            }
        }
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Engine log").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.logText, forType: .string)
                }
                Button("Done") { showLog = false }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(engine.logText).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14).frame(width: 760, height: 460)
    }

    private var fieldFill: Color { Color(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.05) }
    private var fieldBorder: Color { Color(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.10) }

}

// MARK: - Reusable controls

/// An inline “?” that explains on hover and shows a popover on click.
struct HelpButton: View {
    let text: String
    @State private var show = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(text)
                .font(.system(.caption))
                .foregroundStyle(.primary)
                .padding(12).frame(width: 230)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A label on the left with an optional help icon, and its control pinned right.
private func alignRow<Content: View>(title: String, help: String? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
    HStack {
        HStack(spacing: 4) {
            Text(title).font(.system(.callout)).foregroundStyle(.secondary)
            if let help { HelpButton(text: help) }
        }
        Spacer()
        content()
    }
}

private func labeledSlider(_ title: String,
                           _ bound: Binding<Double>,
                           _ range: ClosedRange<Double>,
                           whole: Bool,
                           theme: AppTheme,
                           step: Double = 1,
                           help: String = "") -> some View {
    VStack(alignment: .leading, spacing: 3) {
        HStack {
            HStack(spacing: 4) {
                Text(title).font(.system(.callout)).foregroundStyle(.secondary)
                HelpButton(text: help)
            }
            Spacer()
            Text(formatValue(bound.wrappedValue, whole: whole))
                .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary)
        }
        Slider(value: bound, in: range, step: step).tint(theme.accentColor)
    }
}

private func formatValue(_ v: Double, whole: Bool) -> String {
    whole ? "\(Int(v))" : String(format: "%.1f", v)
}

/// A fixed-size card whose content starts at the top and is clipped to the card.
/// (CardContainer centres an overlay, so tall content spills out of the top unseen.)
struct TopCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.09, green: 0.09, blue: 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A card that sizes to its content (safe inside a ScrollView, unlike CardContainer).
struct SectionCard<Content: View>: View {
    let theme: AppTheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.09, green: 0.09, blue: 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}