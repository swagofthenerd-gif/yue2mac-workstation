//
//  Player.swift — one audio player for everything: a finished take, a reference
//  recording, or a song that is still being made (sections appended as they arrive).
//
//  AVAudioEngine: player node → time-pitch (speed without pitch change) → mixer.
//  The timeline is a list of file segments; seeking reschedules from any frame, and
//  new live sections are appended gaplessly while playing. Only one Player plays at a
//  time (PlayerCenter), and the Playback menu drives whichever played last.
//

import AVFoundation
import Foundation

enum PlayerCenter {
    static weak var active: Player?
}

final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var peaks: [Float] = []          // 20 per second, 0…1
    @Published private(set) var isLive = false               // still growing
    @Published private(set) var waiting = false              // caught up with a growing song
    @Published private(set) var sections = 0
    @Published private(set) var url: URL?
    @Published var loop = false
    @Published var rate: Float = 1 { didSet { pitch.rate = rate } }
    @Published var volume: Float = 1 { didSet { applyVolume() } }
    @Published var muted = false { didSet { applyVolume() } }
    var autoplay = true

    static let peaksPerSecond = 20.0

    private struct Segment { let file: AVAudioFile; let start: AVAudioFramePosition; let frames: AVAudioFramePosition }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    private var segments: [Segment] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var seekBase: AVAudioFramePosition = 0
    private var scheduledEnd: AVAudioFramePosition = 0
    private var generation = 0
    private var started = false
    private var timer: Timer?

    init() {
        engine.attach(node)
        engine.attach(pitch)
    }

    deinit {
        timer?.invalidate()
        node.stop()
        engine.stop()
    }

    var sampleRate: Double { format?.sampleRate ?? 48_000 }
    /// Kept for the live self-test: seconds of audio available.
    var bufferedSeconds: Double { duration }

    // MARK: Loading

    /// Play a single finished file.
    func load(_ url: URL, autoPlay: Bool = false) {
        reset()
        isLive = false
        self.url = url
        guard add(url) else { return }
        schedule(from: 0)
        if autoPlay { play() }
    }

    /// Start a song that will arrive section by section.
    func beginLive() {
        reset()
        isLive = true
    }

    /// Add the next section of a live song.
    func append(_ url: URL) {
        let wasEnd = totalFrames
        guard add(url) else { return }
        sections += 1
        if !started {
            schedule(from: 0)
            if autoplay { play() }
            started = true
        } else if waiting {
            // Playback had caught up: continue exactly where it stopped.
            waiting = false
            schedule(from: wasEnd)
            if isPlaying { node.play() }
        } else if scheduledEnd == wasEnd, let seg = segments.last {
            scheduleSegment(seg, offset: 0, gen: generation)
        }
    }

    /// No more sections are coming.
    func endLive() {
        isLive = false
        if waiting { waiting = false; finishedPlaying() }
    }

    private func reset() {
        timer?.invalidate(); timer = nil
        generation += 1
        node.stop()
        segments = []; totalFrames = 0; seekBase = 0; scheduledEnd = 0
        duration = 0; position = 0; peaks = []; sections = 0
        isPlaying = false; waiting = false; started = false; url = nil
    }

    private func add(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return false }
        if format == nil || format != file.processingFormat {
            if engine.isRunning { engine.stop() }
            format = file.processingFormat
            engine.connect(node, to: pitch, format: file.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)
        }
        segments.append(Segment(file: file, start: totalFrames, frames: file.length))
        totalFrames += file.length
        duration = Double(totalFrames) / sampleRate
        computePeaks(url)
        return true
    }

    private func computePeaks(_ url: URL) {
        let perPeak = AVAudioFrameCount(sampleRate / Player.peaksPerSecond)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let file = try? AVAudioFile(forReading: url),
                  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: perPeak) else { return }
            var out: [Float] = []
            while file.framePosition < file.length {
                guard (try? file.read(into: buf, frameCount: perPeak)) != nil, buf.frameLength > 0,
                      let ch = buf.floatChannelData else { break }
                var peak: Float = 0
                for c in 0..<Int(buf.format.channelCount) {
                    for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[c][i])) }
                }
                out.append(min(1, peak))
            }
            DispatchQueue.main.async { self?.peaks += out }
        }
    }

    // MARK: Transport

    func play() {
        guard !segments.isEmpty else { return }
        if PlayerCenter.active !== self { PlayerCenter.active?.pause() }
        PlayerCenter.active = self
        if !isLive && currentFrame() >= totalFrames - 1 { schedule(from: 0) }   // replay from the top
        if !engine.isRunning { try? engine.start() }
        node.play()
        isPlaying = true
        started = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        position = Double(currentFrame()) / sampleRate
        node.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        pause()
        seek(to: 0)
    }

    func seek(to seconds: Double) {
        guard !segments.isEmpty else { return }
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * sampleRate)
        let wasPlaying = isPlaying
        waiting = false
        schedule(from: min(frame, max(0, totalFrames - 1)))
        position = Double(frame) / sampleRate
        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            node.play()
        }
    }

    func skip(_ seconds: Double) { seek(to: currentSeconds + seconds) }

    var currentSeconds: Double { isPlaying ? Double(currentFrame()) / sampleRate : position }

    // MARK: Scheduling

    private func schedule(from frame: AVAudioFramePosition) {
        generation += 1
        let gen = generation
        node.stop()
        seekBase = frame
        scheduledEnd = frame
        for seg in segments where seg.start + seg.frames > frame {
            scheduleSegment(seg, offset: max(0, frame - seg.start), gen: gen)
        }
    }

    private func scheduleSegment(_ seg: Segment, offset: AVAudioFramePosition, gen: Int) {
        let count = AVAudioFrameCount(seg.frames - offset)
        guard count > 0 else { return }
        let end = seg.start + seg.frames
        node.scheduleSegment(seg.file, startingFrame: offset, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentDone(gen: gen, end: end) }
        }
        scheduledEnd = end
    }

    private func segmentDone(gen: Int, end: AVAudioFramePosition) {
        guard gen == generation, end == totalFrames, isPlaying else { return }
        if isLive {
            waiting = true            // more is coming; append() resumes from here
            position = Double(totalFrames) / sampleRate
        } else {
            finishedPlaying()
        }
    }

    private func finishedPlaying() {
        if loop {
            schedule(from: 0)
            node.play()
            return
        }
        node.stop()
        isPlaying = false
        position = duration
        schedule(from: totalFrames)   // parked at the end; play() restarts from the top
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let t = node.lastRenderTime, let pt = node.playerTime(forNodeTime: t) else {
            return AVAudioFramePosition(position * sampleRate)
        }
        return min(seekBase + pt.sampleTime, waiting ? totalFrames : scheduledEnd)
    }

    private func tick() {
        guard isPlaying else { return }
        position = min(Double(currentFrame()) / sampleRate, duration)
    }

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = muted ? 0 : volume
    }
}
