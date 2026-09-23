//
//  LyricsReportSheet.swift — what a take actually sang, line by line, against the lyrics.
//

import SwiftUI

struct LyricsReportBox: Identifiable {
    let report: LyricsReport
    let id = UUID()
}

struct LyricsReportSheet: View {
    let report: LyricsReport
    @Environment(\.dismiss) private var dismiss

    private var score: Int { max(0, Int(((1 - report.word_error_rate) * 100).rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lyrics check").font(.system(.title3, weight: .semibold))
                Spacer()
                Text("\(report.words_found) of \(report.words_intended) words sung in order")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Heard with Whisper on the isolated vocal. It can mishear sung words, so treat small misses with caution — whole missing lines are the signal.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                Section("Your lines") {
                    ForEach(report.lines, id: \.self) { l in
                        HStack {
                            Image(systemName: icon(l)).foregroundStyle(color(l))
                            Text(l.line)
                            Spacer()
                            Text("\(l.found)/\(l.words)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("What was heard") {
                    ForEach(report.segments, id: \.self) { s in
                        HStack(alignment: .top) {
                            Text(String(format: "%d:%02d", Int(s.start) / 60, Int(s.start) % 60))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 40)
                            Text(s.text).textSelection(.enabled)
                        }
                    }
                    if report.segments.isEmpty { Text("No words detected.").foregroundStyle(.secondary) }
                }
            }
            HStack {
                Text("Word accuracy \(score)%").font(.system(.callout, design: .monospaced))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 520)
    }

    private func icon(_ l: LyricsReport.Line) -> String {
        l.found == l.words ? "checkmark.circle.fill" : (l.found == 0 ? "xmark.circle" : "circle.lefthalf.filled")
    }
    private func color(_ l: LyricsReport.Line) -> Color {
        l.found == l.words ? .green : (l.found == 0 ? .red : .orange)
    }
}
