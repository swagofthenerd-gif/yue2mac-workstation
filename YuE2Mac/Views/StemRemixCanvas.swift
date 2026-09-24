//
//  StemRemixCanvas.swift — the Stem Remix tab: split a song, restyle stems with
//  Stable Audio 3, regenerate a region, add a layer, mix in sync, export.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StemRemixCanvas: View {
    @ObservedObject var session: StemSession
    @ObservedObject var mixer: StemMixer
    let theme: AppTheme
    /// The take currently shown in the result panel, if any.
    let currentTake: URL?

    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceSection
            if !session.tracks.isEmpty {
                Divider()
                mixSection
                Divider()
                restyleSection
                Divider()
                editSection
                Divider()
                exportSection
            }
            if let busy = session.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.callout) }
            } else if let m = session.message {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    // MARK: 1 · Song and split

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Stem Remix", systemImage: "square.3.layers.3d.down.right").font(.system(.body, weight: .semibold))
                HelpButton(text: "Split a song into vocals, drums, bass and the rest (UVR5: BS-RoFormer, then Demucs), restyle any stem with Stable Audio 3, and mix it back — or export the stems to Logic / Ableton. Stable Audio 3 makes instrumental sound only; vocals stay as they are.")
                Spacer()
            }
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .foregroundStyle(dropTargeted ? theme.accentColor : Color.white.opacity(0.2))
                .frame(height: 54)
                .overlay {
                    HStack(spacing: 10) {
                        if let s = session.source {
                            Image(systemName: "music.note").foregroundStyle(theme.accentColor)
                            Text(s.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("Drop a song here, or").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let take = currentTake {
                            Button("Use the current take") { session.open(take) }
                        }
                        Button("Choose…", action: choose)
                    }
                    .padding(.horizontal, 12)
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { session.open(url) } }
                    }
                    return true
                }
            if session.source != nil {
                HStack(spacing: 10) {
                    Picker("Vocals", selection: $session.vocalModel) {
                        ForEach(StemSession.vocalModels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .fixedSize()
                    Picker("Band", selection: $session.bandModel) {
                        ForEach(StemSession.bandModels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .fixedSize()
                    Spacer()
                    Button { Task { await session.split() } } label: {
                        Label(session.tracks.isEmpty ? "Split into stems" : "Split again", systemImage: "scissors")
                    }
                    .buttonStyle(.borderedProminent).tint(theme.accentColor)
                    .disabled(session.busy != nil || !Tools.separatorInstalled)
                }
                if !Tools.separatorInstalled {
                    Text("Install stem separation first: Settings → Stem separation (UVR5).").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: 2 · Mixer

    private var mixSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { mixer.toggle() } label: {
                    Image(systemName: mixer.isPlaying ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderedProminent).tint(theme.accentColor)
                Slider(value: Binding(get: { mixer.position }, set: { mixer.seek(to: $0) }), in: 0...max(mixer.duration, 0.1))
                Text("\(clock(mixer.position)) / \(clock(mixer.duration))").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).fixedSize()
            }
            ForEach(session.tracks) { t in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { t.restyle }, set: { v in
                        if let i = session.tracks.firstIndex(where: { $0.name == t.name }) { session.tracks[i].restyle = v }
                    }))
                    .toggleStyle(.checkbox).labelsHidden().help("Restyle this stem")
                    Text(t.name.capitalized).frame(width: 64, alignment: .leading)
                    Picker("", selection: Binding(get: { t.selected }, set: { session.select(t.name, version: $0) })) {
                        ForEach(Array(t.labels.enumerated()), id: \.offset) { i, l in Text(l).tag(i) }
                    }
                    .labelsHidden().frame(maxWidth: 190)
                    Button("M") { session.toggleMute(t.name) }
                        .buttonStyle(.bordered).tint(t.muted ? .orange : nil).help("Mute")
                    Button("S") { session.toggleSolo(t.name) }
                        .buttonStyle(.bordered).tint(t.solo ? .yellow : nil).help("Solo")
                    Slider(value: Binding(get: { t.gain }, set: { session.setGain(t.name, $0) }), in: 0...1.5)
                        .frame(minWidth: 70)
                    Text(String(format: "%.0f%%", t.gain * 100)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 34)
                }
            }
        }
    }

    // MARK: 3 · Restyle

    private var restyleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Restyle the ticked stems").font(.system(.callout, weight: .semibold))
                Spacer()
                Picker("", selection: $session.sa3Model) {
                    Text("Stable Audio 3 Medium — best (whole song in one pass)").tag("medium")
                    Text("Stable Audio 3 Small — lighter").tag("small-music")
                }
                .labelsHidden().fixedSize()
            }
            TextField("Describe the sound, e.g. \"glitchy granular IDM textures, stuttering edits, bit-crushed\"", text: $session.prompt)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text("Strength").foregroundStyle(.secondary)
                Slider(value: $session.strength, in: 0.2...1.0, step: 0.05).frame(maxWidth: 180)
                Text(String(format: "%.2f", session.strength)).font(.system(size: 11, design: .monospaced))
                HelpButton(text: "How far from the original. Measured on a full song: up to 0.55 the restyle stays locked to the original timing (so it still fits the original vocals); from 0.6 the rhythm is re-invented and drifts. Artist names rarely work — describe the sound instead.")
                Spacer()
                Text("BPM").foregroundStyle(.secondary)
                TextField("", value: $session.bpm, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                    .help("Used to cut long stems at bar lines. 0 = unknown.")
                Button { Task { await session.restyleTicked() } } label: { Label("Restyle", systemImage: "wand.and.rays") }
                    .buttonStyle(.borderedProminent).tint(theme.accentColor)
                    .disabled(session.busy != nil || !Tools.sa3Installed)
            }
            if session.strength > StemSession.timingLockedStrength {
                Label("Above 0.55 the new part no longer follows the song's timing — it won't line up with the other stems or the original vocals.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !Tools.sa3Installed || !Tools.sa3WeightsPresent {
                Text("Needs Stable Audio 3: Settings → Remix (Stable Audio 3). Its download needs a free Hugging Face login.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: 4 · Region and layer

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Change one part, or add a layer").font(.system(.callout, weight: .semibold))
            HStack(spacing: 8) {
                Picker("", selection: $session.regionTrack) {
                    ForEach(session.tracks) { Text($0.name.capitalized).tag($0.name) }
                }
                .labelsHidden().fixedSize()
                Text("from").foregroundStyle(.secondary)
                TextField("", value: $session.regionStart, format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                Text("to").foregroundStyle(.secondary)
                TextField("", value: $session.regionEnd, format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                Text("s").foregroundStyle(.secondary)
                Button("Use playhead") {
                    session.regionStart = (mixer.position * 10).rounded() / 10
                    session.regionEnd = session.regionStart + 8
                }
                TextField("New sound for that part (blank = the restyle prompt)", text: $session.regionPrompt)
                    .textFieldStyle(.roundedBorder)
                Button("Regenerate") { Task { await session.regenerateRegion() } }
                    .disabled(session.busy != nil || !Tools.sa3Installed)
            }
            HStack(spacing: 8) {
                TextField("New layer, e.g. \"warm analog pad, slow swells\"", text: $session.layerPrompt)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await session.addLayer() } } label: { Label("Add layer", systemImage: "plus.square.on.square") }
                    .disabled(session.busy != nil || !Tools.sa3Installed)
            }
        }
    }

    // MARK: 5 · Export

    private var exportSection: some View {
        HStack(spacing: 10) {
            Button {
                Task { if let url = await session.exportMix() { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            } label: { Label("Export mix (WAV)", systemImage: "square.and.arrow.up") }
            Button {
                if let dir = session.exportStems() { NSWorkspace.shared.open(dir) }
            } label: { Label("Export stems for Logic / Ableton", systemImage: "folder.badge.plus") }
            Spacer()
            Text("Muted stems are left out.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { session.open(url) }
    }

    private func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}
