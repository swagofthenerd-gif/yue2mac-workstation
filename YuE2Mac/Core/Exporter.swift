//
//  Exporter.swift — converts a finished take with ffmpeg (MP3 / M4A / FLAC / WAV),
//  optionally mastered to streaming loudness (-14 LUFS, -1 dBTP).
//

import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, flac, wav
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mp3: return "MP3 (320 kbps)"
        case .m4a: return "M4A / AAC (256 kbps)"
        case .flac: return "FLAC (lossless)"
        case .wav: return "WAV (24-bit)"
        }
    }
    var codecArgs: [String] {
        switch self {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "320k"]
        case .m4a: return ["-c:a", "aac", "-b:a", "256k"]
        case .flac: return ["-c:a", "flac"]
        case .wav: return ["-c:a", "pcm_s24le"]
        }
    }
}

enum Exporter {
    /// Writes `<take>[-mastered].<ext>` beside the source and returns it.
    static func export(_ source: URL, as format: ExportFormat, master: Bool) async -> Result<URL, ExportError> {
        guard let ffmpeg = Tools.ffmpeg else { return .failure(.noFFmpeg) }
        let stem = source.deletingPathExtension().lastPathComponent + (master ? "-mastered" : "")
        var dest = source.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(format.rawValue)
        if dest == source { dest = source.deletingLastPathComponent().appendingPathComponent(stem + "-export.wav") }
        var args = ["-y", "-v", "error", "-i", source.path]
        if master { args += ["-af", "loudnorm=I=-14:TP=-1:LRA=11", "-ar", "48000"] }
        args += format.codecArgs + [dest.path]
        let r = await runCapture(ffmpeg, args)
        return r.status == 0 ? .success(dest) : .failure(.ffmpeg(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    enum ExportError: Error {
        case noFFmpeg, ffmpeg(String)
        var message: String {
            switch self {
            case .noFFmpeg: return "Export needs ffmpeg, and none was found on this Mac."
            case .ffmpeg(let e): return "ffmpeg failed: \(e)"
            }
        }
    }
}
