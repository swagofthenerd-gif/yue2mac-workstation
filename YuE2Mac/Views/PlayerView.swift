//
//  PlayerView.swift — transport for a Player: clickable/draggable waveform, restart,
//  ±10 s, play/pause, time, previous/next take, loop, speed, volume and mute.
//

import SwiftUI

struct PlayerView: View {
    @ObservedObject var player: Player
    var theme: AppTheme = .studio
    var compact = false
    /// Optional take navigation (shown when set).
    var previous: (() -> Void)? = nil
    var next: (() -> Void)? = nil

    @State private var scrub: Double?
    @State private var hover: Double?

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            waveform.frame(height: compact ? 26 : 44)
            HStack(spacing: compact ? 6 : 10) {
                if !compact {
                    button("backward.end.fill", "Back to start (⌥⇧←)") { player.seek(to: 0) }
                    if let previous { button("backward.frame.fill", "Previous take", action: previous) }
                    button("gobackward.10", "Back 10 seconds (⌥←)") { player.skip(-10) }
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 12 : 15, weight: .semibold))
                        .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                }
                .buttonStyle(.borderedProminent).tint(theme.accentColor)
                .disabled(player.duration == 0)
                .help("Play / pause (⌥Space)")
                if !compact {
                    button("goforward.10", "Forward 10 seconds (⌥→)") { player.skip(10) }
                    if let next { button("forward.frame.fill", "Next take", action: next) }
                }
                Text(timeLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize()
                if player.isLive {
                    Label(player.waiting ? "catching up" : "LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(player.waiting ? .orange : theme.accentColor)
                }
                Spacer(minLength: 4)
                if !compact {
                    Toggle(isOn: $player.loop) { Image(systemName: "repeat") }
                        .toggleStyle(.button).help("Loop (⌥L)")
                    Menu {
                        ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button { player.rate = Float(r) } label: {
                                if abs(Double(player.rate) - r) < 0.001 { Label(speedText(r), systemImage: "checkmark") } else { Text(speedText(r)) }
                            }
                        }
                    } label: { Text(speedText(Double(player.rate))).font(.system(size: 12, design: .monospaced)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Playback speed (pitch stays the same)")
                }
                Button { player.muted.toggle() } label: {
                    Image(systemName: player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless).help("Mute")
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0); player.muted = false }),
                       in: 0...1)
                    .frame(width: compact ? 60 : 80)
                    .help("Volume")
            }
            .controlSize(.small)
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(player.duration == 0)
            .help(help)
    }

    private func speedText(_ r: Double) -> String {
        r == 1 ? "1×" : String(format: r == r.rounded() ? "%.0f×" : "%.2g×", r)
    }

    private var shown: Double { scrub ?? player.position }

    private var timeLabel: String {
        let left = clock(shown)
        if player.isLive { return "\(left) / \(clock(player.duration)) made" }
        return "\(left) / \(clock(player.duration))"
    }

    private func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Waveform

    private var waveform: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let peaks = player.peaks
                    guard !peaks.isEmpty, player.duration > 0 else {
                        ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)),
                                 with: .color(.white.opacity(0.12)))
                        return
                    }
                    let bars = max(1, Int(size.width / 3))
                    let per = Double(peaks.count) / Double(bars)
                    let played = shown / player.duration
                    for i in 0..<bars {
                        let a = Int(Double(i) * per), b = max(a + 1, Int(Double(i + 1) * per))
                        let slice = peaks[min(a, peaks.count - 1)..<min(b, peaks.count)]
                        let p = CGFloat(slice.max() ?? 0)
                        let bh = max(2, p * size.height)
                        let x = CGFloat(i) * 3
                        let rect = CGRect(x: x, y: (size.height - bh) / 2, width: 2, height: bh)
                        let isPlayed = Double(i) / Double(bars) < played
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(isPlayed ? theme.accentColor : Color.white.opacity(0.28)))
                    }
                }
                if let hover, player.duration > 0 {
                    Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: h)
                        .offset(x: CGFloat(hover / player.duration) * w)
                    Text(clock(hover)).font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 4).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: min(max(0, CGFloat(hover / player.duration) * w - 16), w - 36), y: -2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = Double(max(0, min(1, p.x / w))) * player.duration
                case .ended: hover = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in scrub = Double(max(0, min(1, v.location.x / w))) * player.duration }
                .onEnded { v in
                    player.seek(to: Double(max(0, min(1, v.location.x / w))) * player.duration)
                    scrub = nil
                })
            .help("Click or drag to jump")
        }
    }
}
