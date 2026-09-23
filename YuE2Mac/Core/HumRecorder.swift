//
//  HumRecorder.swift — records a hummed or sung melody from the microphone, to be
//  transcribed by SheetSage2 like any other reference recording.
//

import AVFoundation
import Foundation

final class HumRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0          // 0…1, for a simple meter
    @Published var problem: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var onFinish: ((URL) -> Void)?

    func start(onFinish: @escaping (URL) -> Void) {
        problem = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(onFinish)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.begin(onFinish) } else { self.problem = "Microphone access was declined." }
                }
            }
        default:
            problem = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        }
    }

    private func begin(_ onFinish: @escaping (URL) -> Void) {
        let dir = Tools.recordingsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
        let url = dir.appendingPathComponent("hum \(f.string(from: Date())).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else { problem = "Couldn't start recording."; return }
            recorder = r
            self.onFinish = onFinish
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.elapsed = r.currentTime
                self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        recorder?.stop()   // delegate delivers the file
    }

    func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully ok: Bool) {
        timer?.invalidate(); timer = nil
        isRecording = false
        level = 0
        recorder = nil
        if ok { onFinish?(r.url) } else { problem = "The recording didn't save." }
        onFinish = nil
    }
}
