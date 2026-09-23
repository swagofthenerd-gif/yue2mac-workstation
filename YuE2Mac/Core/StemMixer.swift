//
//  StemMixer.swift — plays several same-length stems in sync (one AVAudioPlayerNode each,
//  started at the same host time) with live per-stem volume, mute and solo.
//

import AVFoundation
import Foundation

final class StemMixer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    private struct Track { let node: AVAudioPlayerNode; var file: AVAudioFile; var gain: Float }

    private let engine = AVAudioEngine()
    private var tracks: [String: Track] = [:]
    private var muted: Set<String> = []
    private var soloed: Set<String> = []
    private var seekBase: AVAudioFramePosition = 0
    private var timer: Timer?
    private var generation = 0

    deinit { stopAll(); engine.stop() }

    private var sampleRate: Double { tracks.values.first?.file.processingFormat.sampleRate ?? 48_000 }
    private var totalFrames: AVAudioFramePosition { tracks.values.map { $0.file.length }.max() ?? 0 }

    /// Load or replace one stem (keeps playing, re-synced, if already playing).
    func set(_ name: String, url: URL, gain: Float = 1) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let wasPlaying = isPlaying
        let at = currentSeconds
        stopAll()
        if let t = tracks[name] {
            engine.disconnectNodeOutput(t.node)
            engine.detach(t.node)
        }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        tracks[name] = Track(node: node, file: file, gain: gain)
        duration = Double(totalFrames) / sampleRate
        applyGains()
        seek(to: at)
        if wasPlaying { play() }
    }

    func remove(_ name: String) {
        guard let t = tracks.removeValue(forKey: name) else { return }
        t.node.stop()
        engine.detach(t.node)
        duration = Double(totalFrames) / sampleRate
    }

    func removeAll() {
        stopAll()
        for t in tracks.values { engine.detach(t.node) }
        tracks = [:]; muted = []; soloed = []
        duration = 0; position = 0; seekBase = 0
    }

    /// Master output level (the self-test runs silent).
    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func setGain(_ name: String, _ gain: Float) { tracks[name]?.gain = gain; applyGains() }
    func setMuted(_ name: String, _ on: Bool) { if on { muted.insert(name) } else { muted.remove(name) }; applyGains() }
    func setSolo(_ name: String, _ on: Bool) { if on { soloed.insert(name) } else { soloed.remove(name) }; applyGains() }

    private func applyGains() {
        for (name, t) in tracks {
            let audible = !muted.contains(name) && (soloed.isEmpty || soloed.contains(name))
            t.node.volume = audible ? t.gain : 0
        }
    }

    // MARK: Transport

    func play() {
        guard !tracks.isEmpty else { return }
        if PlayerCenter.active != nil { PlayerCenter.active?.pause() }
        if !engine.isRunning { try? engine.start() }
        if seekBase >= totalFrames - 1 { seekBase = 0 }
        schedule(from: seekBase)
        // Start every node on the same future host time so the stems stay sample-locked.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        for t in tracks.values { t.node.play(at: start) }
        isPlaying = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        seekBase = AVAudioFramePosition(currentSeconds * sampleRate)
        position = currentSeconds
        stopAll()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let s = max(0, min(seconds, duration))
        seekBase = AVAudioFramePosition(s * sampleRate)
        position = s
        if isPlaying { stopAll(); play() }
    }

    var currentSeconds: Double {
        guard isPlaying, let node = tracks.values.first?.node, let t = node.lastRenderTime,
              let pt = node.playerTime(forNodeTime: t), pt.sampleTime >= 0 else { return position }
        return min(Double(seekBase + pt.sampleTime) / sampleRate, duration)
    }

    private func schedule(from frame: AVAudioFramePosition) {
        generation += 1
        let gen = generation
        for t in tracks.values {
            t.node.stop()
            let count = t.file.length - frame
            guard count > 0 else { continue }
            t.node.scheduleSegment(t.file, startingFrame: frame, frameCount: AVAudioFrameCount(count), at: nil,
                                   completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.maybeFinished(gen) }
            }
        }
    }

    private func maybeFinished(_ gen: Int) {
        guard gen == generation, isPlaying, currentSeconds >= duration - 0.2 else { return }
        stopAll()
        seekBase = 0
        position = 0
    }

    private func stopAll() {
        generation += 1
        timer?.invalidate(); timer = nil
        for t in tracks.values { t.node.stop() }
        isPlaying = false
    }

    private func tick() { position = currentSeconds }
}
