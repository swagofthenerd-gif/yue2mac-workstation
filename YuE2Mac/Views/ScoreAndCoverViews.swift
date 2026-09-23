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
    let theme: AppTheme
    let writeScore: () -> Void

    @State private var check: ScoreCheck?
    @State private var checking = false
    @State private var showPreview = false

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
            .frame(minHeight: 150)
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
                Button("Open…", action: openScore)
                Button("Save…", action: saveScore).disabled(!settings.hasScore)
                Button("Clear") { settings.customABC = "" }.disabled(!settings.hasScore)
            }
            .controlSize(.small)

            Divider()
            shapingControls
        }
        .onAppear(perform: recheck)
        .onChange(of: settings.customABC) { _ in recheck() }
        .sheet(isPresented: $showPreview) { ScorePreviewSheet(abc: settings.customABC) }
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
                Button { choose() } label: { Label("Choose file…", systemImage: "folder") }
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
            .frame(height: 92)
            .overlay {
                if settings.hasReference {
                    VStack(spacing: 6) {
                        Text(URL(fileURLWithPath: settings.referenceAudio).lastPathComponent)
                            .font(.system(.callout, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        AudioPlayer(url: URL(fileURLWithPath: settings.referenceAudio))
                            .id(settings.referenceAudio).frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.secondary)
                        Text("Drop an audio file here").foregroundStyle(.secondary)
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
