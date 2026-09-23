//
//  ScriptInstaller.swift — runs one of the bundled setup scripts (UVR5 separator, LeVo 2,
//  Stable Audio 3) and shows its latest line of output.
//

import Foundation

final class ScriptInstaller: ObservableObject {
    @Published var running = false
    @Published var status = ""
    @Published var failed = false

    static func script(_ name: String) -> String {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts/\(name)").path ?? ""
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("YuE2Mac/scripts/\(name)").path
    }

    @MainActor
    func run(_ name: String, env: [String: String] = [:]) async {
        running = true; failed = false; status = "Starting…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [Self.script(name)]
        var e = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        e["PATH"] = "\(home)/.local/bin:\(home)/.pixi/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        let update: (String) -> Void = { [weak self] line in self?.status = String(line.prefix(160)) }
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("ggml_") })
            if let line { DispatchQueue.main.async { update(line) } }
        }
        let code: Int32 = await withCheckedContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
        out.fileHandleForReading.readabilityHandler = nil
        running = false
        failed = code != 0
        if code == 0 && !status.hasPrefix("✓") { status = "✓ Done" }
    }
}
