//
//  CoverModeInstaller.swift — one-button setup for Cover Mode: a separate Python
//  3.10/3.11 environment with SheetSage2's pinned libraries, plus the SheetSage2
//  and MERT-v2-FullSong weights (~2.7 GB) downloaded into the app's own folder.
//

import Foundation

final class CoverModeInstaller: ObservableObject {
    @Published var running = false
    @Published var status = ""
    @Published var failed = false

    /// SheetSage2 pins libraries that need Python 3.10 or 3.11 on Apple Silicon.
    static func findPython() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let uvDir = "\(home)/.local/share/uv/python"
        if let items = try? fm.contentsOfDirectory(atPath: uvDir) {
            for v in ["3.11", "3.10"] {
                for item in items.sorted().reversed() where item.hasPrefix("cpython-\(v)") && item.contains("aarch64") {
                    candidates.append("\(uvDir)/\(item)/bin/python\(v)")
                }
            }
        }
        candidates += ["/opt/homebrew/opt/python@3.11/bin/python3.11", "/opt/homebrew/opt/python@3.10/bin/python3.10"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static var uv: String? {
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    @MainActor
    func install() async {
        running = true; failed = false
        defer { running = false }
        let dir = Tools.sheetSageDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var python = Self.findPython()
        if python == nil, let uv = Self.uv {
            status = "Getting Python 3.11 (Apple Silicon)…"
            _ = try? await Shell.run(executable: uv, arguments: ["python", "install", "3.11"])
            python = Self.findPython()
        }
        guard let python else {
            return fail("Cover Mode needs an Apple Silicon Python 3.10 or 3.11. Install uv (astral.sh/uv), then try again.")
        }
        let venvPython = Tools.sheetSagePython
        if !FileManager.default.fileExists(atPath: venvPython) {
            status = "Creating Cover Mode's Python environment…"
            guard (try? await Shell.run(executable: python, arguments: ["-m", "venv", dir.appendingPathComponent("venv").path])) == 0 else {
                return fail("Couldn't create the Python environment.")
            }
        }
        status = "Installing SheetSage2's libraries (PyTorch etc., a few minutes)…"
        let pip = dir.appendingPathComponent("venv/bin/pip").path
        _ = try? await Shell.run(executable: pip, arguments: ["install", "-q", "--upgrade", "pip"])
        let pins = ["torch==2.8.0", "torchaudio==2.8.0", "transformers==4.45.2", "huggingface-hub==0.36.0",
                    "safetensors==0.5.3", "numpy==1.24.3", "scipy==1.13.1", "mir_eval==0.8.2",
                    "pretty_midi==0.2.10", "mido==1.3.3", "setuptools==78.1.1", "soundfile"]
        guard (try? await Shell.run(executable: pip, arguments: ["install", "-q"] + pins)) == 0 else {
            return fail("Installing the libraries failed. Check your connection and retry.")
        }
        // Stems / vocal isolation (Demucs) and the lyrics check (Whisper on MLX), held to the pins above.
        status = "Installing stem splitting and lyrics recognition…"
        let constraints = dir.appendingPathComponent("constraints.txt")
        try? pins.prefix(7).joined(separator: "\n").write(to: constraints, atomically: true, encoding: .utf8)
        guard (try? await Shell.run(executable: pip, arguments: ["install", "-q", "-c", constraints.path,
                                                                 "demucs==4.1.0", "mlx-whisper==0.4.3"])) == 0 else {
            return fail("Installing Demucs / Whisper failed. Check your connection and retry.")
        }
        status = "Downloading SheetSage2 and MERT-v2 (about 2.7 GB)…"
        let script = """
        import sys
        from huggingface_hub import snapshot_download
        for repo in ("m-a-p/SheetSage2", "m-a-p/MERT-v2-FullSong"):
            snapshot_download(repo_id=repo, local_dir=sys.argv[1] + "/" + repo.split("/")[1])
        """
        guard (try? await Shell.run(executable: venvPython, arguments: ["-c", script, Tools.sheetSageModels])) == 0 else {
            return fail("The model download failed. Check your connection and retry.")
        }
        status = "Downloading the stem and lyrics models (about 1.6 GB)…"
        _ = try? await Shell.run(executable: venvPython,
                                 arguments: [Tools.engineDir.appendingPathComponent("audio_tools.py").path,
                                             "--models", Tools.sheetSageModels, "fetch"])
        status = SideTasks.toolsInstalled ? "Cover Mode, stems and lyrics check are ready."
                                          : "Install finished, but some files are missing."
        failed = !SideTasks.toolsInstalled
    }

    @MainActor
    private func fail(_ message: String) {
        status = message
        failed = true
    }
}
