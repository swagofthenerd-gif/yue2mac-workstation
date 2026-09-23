//
//  HistorySheet.swift — every song made with the workstation, with its takes,
//  settings and score, ready to replay, reload or reuse.
//

import SwiftUI
import AppKit

struct HistorySheet: View {
    @ObservedObject var settings: SettingsStore
    let onReuseScore: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var songs: [SongEntry] = []
    @State private var selection: SongEntry?
    @State private var take: TakeRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(.title3, weight: .semibold))
                Spacer()
                Button { NSWorkspace.shared.open(AppPaths.outputDir) } label: { Label("Open folder", systemImage: "folder") }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                List(songs, selection: $selection) { song in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.system(.callout, weight: .semibold)).lineLimit(1)
                        Text(song.style).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("\(song.takes.count) take\(song.takes.count == 1 ? "" : "s")" + (song.hasScore ? " · score" : ""))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .tag(song)
                    .padding(.vertical, 2)
                }
                .frame(width: 300)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { songs = SongEntry.library(); selection = songs.first; take = songs.first?.takes.first }
        .onChange(of: selection) { s in take = s?.takes.first }
    }

    @ViewBuilder
    private var detail: some View {
        if let song = selection, let record = record(song) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if song.takes.count > 1 {
                        Picker("Take", selection: $take) {
                            ForEach(song.takes) { t in Text("\(t.file) · seed \(t.seed)").tag(Optional(t)) }
                        }
                        .fixedSize()
                    }
                    if let t = take {
                        AudioPlayer(url: song.takeURL(t)).id(song.takeURL(t))
                        if t.semantic_truncated {
                            Label("This take hit the length limit — its ending may be cut.", systemImage: "scissors")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Group {
                        row("Style", record.request.style)
                        row("Planning", record.request.cot + (record.request.abc_supplied == true ? " · your score" : ""))
                        if record.request.instrumental == true { row("Vocals", "Instrumental") }
                        if let bpm = record.request.tempo { row("Tempo", "\(bpm) BPM") }
                        row("Quality", "\(record.settings.steps ?? 32) steps · CFG \(String(format: "%.2f", record.settings.cfg_scale ?? 1))")
                        row("Length cap", "\(record.settings.max_tokens ?? 0) tokens")
                    }
                    Text("Lyrics").font(.caption).foregroundStyle(.secondary)
                    Text(record.request.lyrics.isEmpty ? "—" : record.request.lyrics)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Load these settings") { load(record); dismiss() }
                        if song.hasScore {
                            Button("Reuse its score") { onReuseScore(song.scoreURL); dismiss() }
                                .help("New takes of the same song: same notes and chords, new performance")
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.folder]) }
                    }
                    .controlSize(.small)
                }
                .padding(16)
            }
        } else {
            Text(songs.isEmpty ? "No songs yet — generated songs appear here." : "Select a song")
                .foregroundStyle(.secondary)
        }
    }

    private func record(_ song: SongEntry) -> SongRecord? {
        guard let data = try? Data(contentsOf: song.folder.appendingPathComponent("song.json")) else { return nil }
        return try? JSONDecoder().decode(SongRecord.self, from: data)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).font(.callout).textSelection(.enabled)
        }
    }

    private func load(_ r: SongRecord) {
        // The engine records the style/lyrics it actually used; strip its instrumental suffix back off.
        var style = r.request.style
        if r.request.instrumental == true, style.hasSuffix(", instrumental, no vocals") {
            style = String(style.dropLast(", instrumental, no vocals".count))
        }
        settings.style = style
        if r.request.instrumental != true { settings.lyrics = r.request.lyrics }
        settings.instrumental = r.request.instrumental ?? false
        if let s = r.settings.steps { settings.steps = Double(s) }
        if let c = r.settings.cfg_scale { settings.cfgScale = c }
    }
}
