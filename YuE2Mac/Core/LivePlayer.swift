//
//  LivePlayer.swift — plays a song while it's still being made. The engine writes
//  each finished section as a WAV and announces it; this queues the sections
//  back-to-back on one AVAudioPlayerNode so playback is gapless while the engine
//  stays ahead, and simply waits if it falls behind.
//

import AVFoundation
import Foundation

final class LivePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var sections = 0
    @Published var autoplay = true

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var scheduledFrames: AVAudioFramePosition = 0
    private var timer: Timer?
    private var started = false

    /// Clear everything for a new song.
    func reset() {
        stop()
        bufferedSeconds = 0; position = 0; sections = 0; scheduledFrames = 0
        started = false
    }

    /// Queue the next section the engine finished.
    func enqueue(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return }
        if format == nil || format != file.processingFormat {
            format = file.processingFormat
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        }
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buffer, completionHandler: nil)
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
        bufferedSeconds = Double(scheduledFrames) / file.processingFormat.sampleRate
        sections += 1
        if autoplay && !started { play() }
    }

    func play() {
        guard format != nil else { return }
        if !engine.isRunning { try? engine.start() }
        node.play()
        started = true
        isPlaying = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func pause() {
        node.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        timer?.invalidate(); timer = nil
        node.stop()
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    private func tick() {
        guard let t = node.lastRenderTime, let pt = node.playerTime(forNodeTime: t), let f = format else { return }
        position = min(Double(pt.sampleTime) / f.sampleRate, bufferedSeconds)
    }

    /// True when playback has caught up with what's been made so far.
    var waiting: Bool { isPlaying && bufferedSeconds - position < 0.3 }
}
