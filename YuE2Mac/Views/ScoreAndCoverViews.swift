//
//  ScoreAndCoverViews.swift — the two extra canvases beside Lyrics:
//  Score: paste, write, check, preview and shape an ABC score that replaces the plan.
//  Cover: drop or record a reference, transcribe it with SheetSage2 into the score.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Score

struct ScoreCanvas: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: GenerationEngine
    @ObservedObject var side: SideTasks
    let theme: AppTheme
    let writeScore: () -> Void

    @State private var check: ScoreCheck?
    @State private var checking = false
    @State private var showPreview = false
    @State private var showArrange = false
    @State private var beforeAI: String?
    @State private var aiNotes: String?
    @State private var showAINotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Custom ABC Notation Score (Optional)", systemImage: "music.quarternote.3")
                    .font(.system(.body, weight: .semibold))
                HelpButton(text: "A score here replaces the model's own planning: the song follows these notes. Leave it empty to let YuE2 compose. Scores with chord symbols lock the harmony (full mode); melody-only scores leave the accompaniment free (melody mode).")
                Spacer()
                Button { writeScore() } label: { Label("Write one for me", systemImage: "wand.and.stars") }
                    .disabled(engine.isRunning)
                    .help("Let YuE2 write a score from your style and lyrics — no audio yet (about 20 s)")
            }
            .controlSize(.small)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $settings.customABC)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                if settings.customABC.isEmpty {
                    Text("Paste your .abc score code here to bypass auto-composition…")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .frame(height: 210)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))

            HStack(spacing: 8) {
                if checking { ProgressView().controlSize(.small) }
                if let check {
                    Image(systemName: check.ok ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(check.ok ? .green : .orange)
                    Text(check.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if settings.hasScore {
                    Text("Not checked yet").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("Empty — YuE2 will compose its own score").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Preview") { showPreview = true }.disabled(!settings.hasScore)
                    .help("See it as sheet music and hear the notes")
                Button("Arrange…") { showArrange = true }.disabled(!settings.hasScore || check?.ok != true)
                    .help("Reorder, repeat or drop sections")
                Button("Open…", action: openScore)
                Button("Save…", action: saveScore).disabled(!settings.hasScore)
                Button("Clear") { settings.customABC = "" }.disabled(!settings.hasScore)
            }
            .controlSize(.small)
            if !settings.stashedScore.isEmpty {
                HStack {
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                    Text("Your previous score was set aside when you picked a new reference recording, so the recording's own melody is used.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore it") { settings.customABC = settings.stashedScore; settings.stashedScore = ""; settings.scoreSource = "manual" }
                    Button("Discard") { settings.stashedScore = "" }
                }
                .controlSize(.small)
            }

            Divider()
            aiRow
            shapingControls
        }
        .onAppear(perform: recheck)
        .onChange(of: settings.customABC) { _ in recheck() }
        .sheet(isPresented: $showPreview) { ScorePreviewSheet(abc: settings.customABC) }
        .sheet(isPresented: $showArrange) { ArrangeSheet(settings: settings, side: side) }
    }

    private var aiRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(theme.accentColor)
                TextField("Ask Claude to edit: \"jazzier chords\", \"minor key feel\", \"a sax solo in the interlude\"…",
                          text: $settings.aiInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runAI)
                Picker("", selection: $settings.aiContract) {
                    ForEach(AIContract.allCases) { c in Text(c.title).tag(c.rawValue) }
                }
                .labelsHidden().fixedSize()
                .help("What Claude must not change. Every edit is checked with YuE2's official score tools before it's accepted.")
                if side.busy != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Edit", action: runAI)
                        .disabled(!settings.hasScore || check?.ok != true
                                  || settings.aiInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 8) {
                if let busy = side.busy { Text(busy).font(.caption).foregroundStyle(.secondary) }
                else if let m = side.message { Text(m).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                if aiNotes != nil {
                    Button("What changed") { showAINotes = true }
                        .popover(isPresented: $showAINotes) {
                            ScrollView { Text(aiNotes ?? "").font(.callout).textSelection(.enabled).padding(12) }
                                .frame(width: 420, height: 260)
                        }
                }
                if let old = beforeAI {
                    Button("Undo AI edit") { settings.customABC = old; beforeAI = nil; aiNotes = nil }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .controlSize(.small)
    }

    private func runAI() {
        guard side.busy == nil, settings.hasScore else { return }
        let original = settings.customABC
        let contract = AIContract(rawValue: settings.aiContract) ?? .keepMelody
        Task {
            let (edited, res) = await side.aiEdit(score: original, instruction: settings.aiInstruction,
                                                  contract: contract, style: settings.style)
            await MainActor.run {
                if let edited {
                    beforeAI = original
                    settings.customABC = edited
                    aiNotes = (res?.explanation ?? "") + (res?.melody_unchanged == true ? "\n\n✓ Verified: melody unchanged." : "")
                }
            }
        }
    }

    private var shapingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Toggle(isOn: $settings.tempoOverride) {
                    HStack(spacing: 4) {
                        Text("Change tempo")
                        HelpButton(text: "Rewrites the score's tempo. Note lengths are relative, so the whole song follows the new BPM. Mention the BPM in your style prompt too.")
                    }
                }
                Stepper(value: $settings.tempoBPM, in: 40...240, step: 1) {
                    Text("\(Int(settings.tempoBPM)) BPM").font(.system(.callout, design: .monospaced))
                }
                .disabled(!settings.tempoOverride)
                Spacer()
            }
            HStack(spacing: 14) {
                Toggle(isOn: $settings.stripChords) {
                    HStack(spacing: 4) {
                        Text("Remove chords")
                        HelpButton(text: "Drops the chord symbols so YuE2 re-harmonises freely around the melody (melody mode). The official way to make a cover in a new style.")
                    }
                }
                Picker("Keep", selection: $settings.keepVoice) {
                    Text("Both melodies").tag("both")
                    Text("Vocal only").tag("Vocal")
                    Text("Instrument only").tag("Ins")
                }
                .fixedSize()
                .help("Scores carry a sung melody and an instrumental melody. Keeping one replaces the other with rests (chords are removed too).")
                Spacer()
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    private func recheck() {
        let text = settings.customABC
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { check = nil; return }
        checking = true
        Task {
            let result = await checkScore(text)
            await MainActor.run {
                if settings.customABC == text { check = result; checking = false }
            }
        }
    }

    private func openScore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "abc") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url) {
            settings.customABC = text
            settings.scoreSource = "manual"
        }
    }

    private func saveScore() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "score.abc"
        if panel.runModal() == .OK, let url = panel.url {
            try? settings.customABC.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Cover

struct CoverCanvas: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: GenerationEngine
    let theme: AppTheme
    let transcribe: () -> Void
    let showScore: () -> Void

    @StateObject private var recorder = HumRecorder()
    @StateObject private var refPlayer = Player()
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Upload Reference Audio (For Covers & Remixes)", systemImage: "waveform.badge.plus")
                    .font(.system(.body, weight: .semibold))
                HelpButton(text: "SheetSage2 listens to the recording and writes down its melody as a score. YuE2 then performs that melody in the style you type, with your lyrics. The original audio itself is not reused.")
                Spacer()
            }

            if !Tools.coverModeInstalled {
                Label("Cover Mode isn't installed yet — open Settings (gear icon) → Install Cover Mode.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            dropZone

            HStack(spacing: 10) {
                Button { choose() } label: { Label(settings.hasReference ? "Choose another…" : "Choose file…", systemImage: "folder") }
                Button {
                    if recorder.isRecording { recorder.stop() }
                    else { recorder.start { url in settings.referenceAudio = url.path } }
                } label: {
                    Label(recorder.isRecording ? "Stop recording" : "Hum a melody",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "mic")
                }
                .tint(recorder.isRecording ? .red : nil)
                if recorder.isRecording {
                    ProgressView(value: Double(recorder.level)).frame(width: 80)
                    Text(String(format: "%d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60))
                        .font(.system(.callout, design: .monospaced))
                }
                Spacer()
                if settings.hasReference {
                    Button("Remove") { settings.referenceAudio = "" }
                }
            }
            .controlSize(.small)
            if let p = recorder.problem { Text(p).font(.caption).foregroundStyle(.orange) }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("Transcribe", selection: $settings.coverChords) {
                    Text("Melody only — new harmony (recommended)").tag(false)
                    Text("Melody + chords — keep the original harmony").tag(true)
                }
                .fixedSize()
                Picker("Stick to the original", selection: $settings.coverFaithfulness) {
                    Text("Faithful — follows the melody tightly (recommended)").tag("faithful")
                    Text("Balanced").tag("balanced")
                    Text("Loose — freer, more variation").tag("loose")
                }
                .fixedSize()
                .help("Measured on a real cover: Faithful kept the reference melody in 85–91% of every take; the model's default (Loose) ranged 60–84%. Faithful can sound a little more restrained.")
                HStack(spacing: 10) {
                    Toggle("Pick the closest take automatically", isOn: $settings.pickClosestTake)
                    Stepper(value: $settings.takes, in: 1...8) {
                        Text("\(Int(settings.takes)) take\(settings.takes == 1 ? "" : "s")").font(.system(.callout, design: .monospaced))
                    }
                    .help("Takes vary: making 2–3 and keeping the one that follows the melody best is the most reliable way to get close.")
                }
                .toggleStyle(.switch)
                Toggle(isOn: $settings.isolateVocals) {
                    HStack(spacing: 4) {
                        Text("Isolate the vocal first")
                        HelpButton(text: "Melody-only covers: separates the singing from the band (Demucs) before transcribing, for a cleaner melody. Not used with chords, which need the band.")
                    }
                }
                .toggleStyle(.switch)
                .disabled(!SideTasks.toolsInstalled || settings.coverChords)
                HStack {
                    Button { transcribe() } label: { Label("Transcribe now", systemImage: "text.viewfinder") }
                        .disabled(!settings.hasReference || engine.isRunning || !Tools.coverModeInstalled)
                        .help("Write the score now so you can check or fix it in the Score tab before generating")
                    if settings.hasScore { Button("Open in Score tab", action: showScore) }
                    Spacer()
                    if let t = engine.lastTranscription {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([t.appendingPathComponent("melody.mid")]) } label: {
                            Label("MIDI files", systemImage: "pianokeys")
                        }
                        .help("SheetSage2 also saves melody, vocal, instrument and chord MIDI plus beats and key")
                    }
                }
                Text(coverHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.small)
        }
    }

    private var coverHint: String {
        if !settings.hasReference { return "Drop a song, stem or voice memo (mp3, wav, m4a, flac, aiff…), or hum one. Then press Generate: it transcribes first, then sings your lyrics to that melody in your style." }
        if settings.hasScore { return "A score is already in the Score tab, so Generate will use it. Clear it there to transcribe this recording again." }
        return "Press Generate to transcribe and render in one go, or Transcribe now to review the score first. Lyrics should fit the melody's phrasing."
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(dropTargeted ? theme.accentColor : Color.white.opacity(0.2))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(dropTargeted ? 0.08 : 0.03)))
            .frame(height: 118)
            .overlay {
                if settings.hasReference {
                    VStack(spacing: 6) {
                        Text(URL(fileURLWithPath: settings.referenceAudio).lastPathComponent)
                            .font(.system(.callout, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        PlayerView(player: refPlayer, theme: theme, compact: true)
                            .frame(maxWidth: 520)
                            .onAppear { refPlayer.load(URL(fileURLWithPath: settings.referenceAudio)) }
                            .onChange(of: settings.referenceAudio) { p in if !p.isEmpty { refPlayer.load(URL(fileURLWithPath: p)) } }
                    }
                    .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 8) {
                        Button { choose() } label: {
                            Label("Upload your song…", systemImage: "square.and.arrow.up")
                                .padding(.horizontal, 10).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent).tint(theme.accentColor).controlSize(.large)
                        Text("or drag an audio file here · mp3, wav, m4a, flac, aiff").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { settings.referenceAudio = url.path }
                }
                return true
            }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url { settings.referenceAudio = url.path }
    }
}


// MARK: - Arrange sections

struct ArrangeSheet: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var side: SideTasks
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [ScoreSection] = []
    @State private var order: [Int] = []
    @State private var reorderLyrics = true
    @State private var error: String?
    @State private var loading = true

    /// Lyrics split into [tag] blocks; used when their count matches the score's sections.
    private var lyricBlocks: [String] {
        var blocks: [String] = [], current = ""
        for line in settings.lyrics.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(current.trimmingCharacters(in: .newlines)); current = ""
            }
            current += line + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(current.trimmingCharacters(in: .newlines)) }
        return blocks
    }
    private var lyricsMatch: Bool { !sections.isEmpty && lyricBlocks.count == sections.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Arrange sections").font(.system(.title3, weight: .semibold))
                Spacer()
                Text(totalLength).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("Reorder, repeat or drop parts of the song. Moved sections keep their own key and meter.")
                .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView() }
            List {
                ForEach(Array(order.enumerated()), id: \.offset) { pos, idx in
                    HStack {
                        Text("\(pos + 1).").font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 28)
                        Text(sections.first { $0.index == idx }?.name.capitalized ?? "?").font(.body)
                        Text("from part \(idx + 1)").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Text(length(idx)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Button { move(pos, -1) } label: { Image(systemName: "arrow.up") }.disabled(pos == 0)
                        Button { move(pos, 1) } label: { Image(systemName: "arrow.down") }.disabled(pos == order.count - 1)
                        Button { order.insert(idx, at: pos + 1) } label: { Image(systemName: "plus.square.on.square") }
                            .help("Repeat this section")
                        Button { order.remove(at: pos) } label: { Image(systemName: "trash") }.disabled(order.count == 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(minHeight: 260)
            Toggle("Rearrange the lyric sections the same way", isOn: $reorderLyrics)
                .disabled(!lyricsMatch)
                .help(lyricsMatch ? "Your lyrics have one [section] block per score section."
                                  : "Your lyrics have \(lyricBlocks.count) [section] blocks and the score has \(sections.count), so they can't be matched automatically.")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Reset") { order = sections.map(\.index) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction).disabled(order.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .task {
            sections = await side.sections(of: settings.customABC)
            order = sections.map(\.index)
            loading = false
            if sections.isEmpty { error = side.message ?? "Couldn't read this score's sections." }
        }
    }

    private func length(_ idx: Int) -> String {
        guard let s = sections.first(where: { $0.index == idx })?.seconds else { return "" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private var totalLength: String {
        let total = order.compactMap { i in sections.first { $0.index == i }?.seconds }.reduce(0, +)
        return String(format: "Total %d:%02d", Int(total) / 60, Int(total) % 60)
    }

    private func move(_ pos: Int, _ by: Int) {
        let target = pos + by
        guard order.indices.contains(target) else { return }
        order.swapAt(pos, target)
    }

    private func apply() {
        Task {
            guard let text = await side.arrange(settings.customABC, order: order) else {
                error = side.message ?? "That arrangement didn't produce a valid score."; return
            }
            let blocks = lyricBlocks
            settings.customABC = text
            if reorderLyrics && lyricsMatch {
                settings.lyrics = order.map { blocks[$0] }.joined(separator: "\n\n") + "\n"
            }
            dismiss()
        }
    }
}
