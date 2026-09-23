//
//  ScorePreview.swift — renders an ABC score as sheet music with abcjs (bundled)
//  and plays it back, so a plan or transcription can be checked before any audio
//  is generated. Playback instruments load from the abcjs soundfont site.
//

import SwiftUI
import WebKit

struct ScorePreviewSheet: View {
    let abc: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Score preview").font(.system(.title3, weight: .semibold))
                Spacer()
                Text("A plain instrument playback of the notes — not what YuE2 will sound like.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScoreWebView(abc: abc)
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

struct ScoreWebView: NSViewRepresentable {
    let abc: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        load(web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    private func load(_ web: WKWebView) {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("abcjs"),
              let js = try? String(contentsOf: dir.appendingPathComponent("abcjs-basic-min.js")),
              let css = try? String(contentsOf: dir.appendingPathComponent("abcjs-audio.css")) else {
            web.loadHTMLString("<p style='font-family:-apple-system;color:#c00'>The sheet-music library is missing from this build.</p>", baseURL: nil)
            return
        }
        // The score goes in as a JSON string literal, so any character is safe.
        let literal = (try? String(data: JSONEncoder().encode(abc), encoding: .utf8)) ?? "\"\""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, sans-serif; margin: 12px; background: #fff; color: #111; }
        #paper svg { max-width: 100%; }
        #err { color: #b00; white-space: pre-wrap; }
        \(css)
        </style></head><body>
        <div id="audio"></div><div id="err"></div><div id="paper"></div>
        <script>\(js)</script>
        <script>
        const abc = \(literal);
        const visual = ABCJS.renderAbc("paper", abc, { responsive: "resize", add_classes: true })[0];
        if (ABCJS.synth.supportsAudio()) {
          const ctl = new ABCJS.synth.SynthController();
          ctl.load("#audio", null, { displayLoop: true, displayRestart: true, displayPlay: true,
                                     displayProgress: true, displayWarp: true });
          ctl.setTune(visual, false).catch(e => { document.getElementById("err").textContent = "Playback unavailable: " + e; });
        } else {
          document.getElementById("err").textContent = "Playback isn't supported here.";
        }
        </script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://paulrosen.github.io/"))
    }
}
