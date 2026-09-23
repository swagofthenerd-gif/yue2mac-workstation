//
//  GenSettings.swift — the user's chosen engine inputs, persisted in UserDefaults.
//

import Foundation

/// Available model quantizations are discovered by scanning the engine folder,
/// but a model name can also be stored so it survives relaunch.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }

    /// Model variant the user chose at install time (defaults to the autoscanned one).
    var preferredVariant: String {
        get { defaults.string(forKey: "preferredVariant") ?? "" }
        set { defaults.set(newValue, forKey: "preferredVariant") }
    }

    @Published var engineRoot: String? {
        didSet { defaults.set(engineRoot, forKey: "engineRoot") }
    }
    @Published var modelDir: String? {
        didSet { defaults.set(modelDir, forKey: "modelDir") }
    }

    // Persisted generation preferences.
    @Published var style: String {
        didSet { defaults.set(style, forKey: "style") }
    }
    @Published var lyrics: String {
        didSet { defaults.set(lyrics, forKey: "lyrics") }
    }
    @Published var planning: String {          // auto | full | melody | off
        didSet { defaults.set(planning, forKey: "planning") }
    }
    @Published var steps: Double {
        didSet { defaults.set(steps, forKey: "steps") }
    }
    @Published var cfgScale: Double {
        didSet { defaults.set(cfgScale, forKey: "cfgScale") }
    }
    @Published var maxTokens: Double {
        didSet { defaults.set(maxTokens, forKey: "maxTokens") }
    }
    @Published var seed: String {
        didSet { defaults.set(seed, forKey: "seed") }
    }
    @Published var instrumental: Bool {
        didSet { defaults.set(instrumental, forKey: "instrumental") }
    }

    // Score (ABC) input — when non-empty it replaces the model's own plan.
    @Published var customABC: String { didSet { defaults.set(customABC, forKey: "customABC") } }
    @Published var stripChords: Bool { didSet { defaults.set(stripChords, forKey: "stripChords") } }
    @Published var keepVoice: String { didSet { defaults.set(keepVoice, forKey: "keepVoice") } }   // both | Vocal | Ins
    @Published var tempoOverride: Bool { didSet { defaults.set(tempoOverride, forKey: "tempoOverride") } }
    @Published var tempoBPM: Double { didSet { defaults.set(tempoBPM, forKey: "tempoBPM") } }

    // Cover mode — a reference recording transcribed by SheetSage2.
    @Published var referenceAudio: String { didSet { defaults.set(referenceAudio, forKey: "referenceAudio") } }
    @Published var coverChords: Bool { didSet { defaults.set(coverChords, forKey: "coverChords") } }

    // Length and takes.
    @Published var autoLength: Bool { didSet { defaults.set(autoLength, forKey: "autoLength") } }
    @Published var takes: Double { didSet { defaults.set(takes, forKey: "takes") } }

    // Sampling — music stage, then score-plan stage. Defaults are the model's own.
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: "temperature") } }
    @Published var topP: Double { didSet { defaults.set(topP, forKey: "topP") } }
    @Published var topK: Double { didSet { defaults.set(topK, forKey: "topK") } }
    @Published var repetitionPenalty: Double { didSet { defaults.set(repetitionPenalty, forKey: "repetitionPenalty") } }
    @Published var planTemperature: Double { didSet { defaults.set(planTemperature, forKey: "planTemperature") } }
    @Published var planTopP: Double { didSet { defaults.set(planTopP, forKey: "planTopP") } }
    @Published var planTopK: Double { didSet { defaults.set(planTopK, forKey: "planTopK") } }

    // Export.
    @Published var masterLoudness: Bool { didSet { defaults.set(masterLoudness, forKey: "masterLoudness") } }

    static let modelDefaults = (temperature: 1.0, topP: 0.95, topK: 100.0, repetitionPenalty: 1.2,
                                planTemperature: 0.7, planTopP: 0.9, planTopK: 30.0,
                                steps: 32.0, cfgScale: 1.0)
    static let tokenCap = 9000.0

    /// `defaults` is only swapped out by the self-test, so it never touches real settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .studio
        engineRoot = defaults.string(forKey: "engineRoot")
        modelDir = defaults.string(forKey: "modelDir")
        style = defaults.string(forKey: "style") ?? "English, indie pop, bright acoustic guitar, soft drums, warm lead vocal"
        lyrics = defaults.string(forKey: "lyrics") ?? ""
        planning = defaults.string(forKey: "planning") ?? "auto"
        let d = SettingsStore.modelDefaults
        steps = Self.number(defaults, "steps", d.steps)
        // The model's authors use 1.0 with a score; the original app default of 5.0 was slower and off-spec.
        cfgScale = Self.number(defaults, "cfgScale", d.cfgScale)
        maxTokens = min(Self.number(defaults, "maxTokens", 4500), SettingsStore.tokenCap)
        seed = defaults.string(forKey: "seed") ?? ""
        instrumental = defaults.bool(forKey: "instrumental")
        customABC = defaults.string(forKey: "customABC") ?? ""
        stripChords = defaults.bool(forKey: "stripChords")
        keepVoice = defaults.string(forKey: "keepVoice") ?? "both"
        tempoOverride = defaults.bool(forKey: "tempoOverride")
        tempoBPM = Self.number(defaults, "tempoBPM", 120)
        referenceAudio = defaults.string(forKey: "referenceAudio") ?? ""
        coverChords = defaults.bool(forKey: "coverChords")
        autoLength = defaults.object(forKey: "autoLength") as? Bool ?? true
        takes = Self.number(defaults, "takes", 1)
        temperature = Self.number(defaults, "temperature", d.temperature)
        topP = Self.number(defaults, "topP", d.topP)
        topK = Self.number(defaults, "topK", d.topK)
        repetitionPenalty = Self.number(defaults, "repetitionPenalty", d.repetitionPenalty)
        planTemperature = Self.number(defaults, "planTemperature", d.planTemperature)
        planTopP = Self.number(defaults, "planTopP", d.planTopP)
        planTopK = Self.number(defaults, "planTopK", d.planTopK)
        masterLoudness = defaults.bool(forKey: "masterLoudness")
    }

    private static func number(_ d: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        (d.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }

    /// Put every sampling control back to the model's own values.
    func resetSampling() {
        let d = SettingsStore.modelDefaults
        temperature = d.temperature; topP = d.topP; topK = d.topK; repetitionPenalty = d.repetitionPenalty
        planTemperature = d.planTemperature; planTopP = d.planTopP; planTopK = d.planTopK
    }

    /// Fast previews: fewer refinement steps, no extra guidance pass.
    func applyDraft() { steps = 12; cfgScale = 1.0 }
    /// The model's reference quality.
    func applyFinal() { steps = SettingsStore.modelDefaults.steps; cfgScale = SettingsStore.modelDefaults.cfgScale }

    var hasScore: Bool { !customABC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasReference: Bool { !referenceAudio.isEmpty && FileManager.default.fileExists(atPath: referenceAudio) }

    /// Fold the instrumental toggle into the real style prompt sent to the model.
    func effectiveStyle() -> String {
        guard instrumental else { return style }
        let base = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "instrumental, no vocals"
        return base.isEmpty ? suffix : base + ", " + suffix
    }

    /// Strip lyrics to structure tags only for instrumentals (the model's known quirk).
    func effectiveLyrics() -> String {
        guard instrumental else { return lyrics }
        let lines = lyrics.components(separatedBy: .newlines)
        let tags = lines.filter { line in
            line.hasPrefix("[") && line.hasSuffix("]")
        }
        return tags.count > 0 ? tags.joined(separator: "\n") : "[Intro]\n[Instrumental]"
    }

    /// A seed actually passed to the CLI. Empty → a fresh random seed.
    func resolvedSeed() -> Int? {
        let trimmed = seed.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) { return n }
        return Int.random(in: 0...999_999)
    }
}