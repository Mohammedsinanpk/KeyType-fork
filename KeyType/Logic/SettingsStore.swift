//
//  SettingsStore.swift
//  KeyType
//
//  User-facing settings backed by UserDefaults: model selection, completion length, per-app
//  toggles, and the privacy switches that gate sensitive context (writing history, clipboard,
//  screen/OCR). History/clipboard/OCR default to OFF — KeyType only uses sensitive context the
//  user has explicitly opted into. The pipeline (CompletionController / WritingHistoryRecorder /
//  AppCompatibility wiring) reads these; SettingsView writes them. See ADR-023.
//

import AutocompleteCore
import Foundation
import Observation

/// Completion length presets, mapped to the decoder's token/width budget.
enum CompletionLength: String, CaseIterable, Identifiable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .long: return "Long"
        }
    }

    /// Base `maxCompletionTokens` for a request (token-healing may widen this at runtime).
    var maxCompletionTokens: Int {
        switch self {
        case .short: return 2
        case .medium: return 4
        case .long: return 8
        }
    }

    /// Base `maxDisplayWidth` (characters) for a candidate.
    var maxDisplayWidth: Int {
        switch self {
        case .short: return 30
        case .medium: return 60
        case .long: return 120
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let historyEnabled = "KeyType.settings.historyEnabled"
        static let clipboardEnabled = "KeyType.settings.clipboardEnabled"
        static let ocrEnabled = "KeyType.settings.ocrEnabled"
        static let completionLength = "KeyType.settings.completionLength"
        static let selectedModelFilename = "KeyType.settings.selectedModelFilename"
        static let perAppDisabled = "KeyType.settings.perAppDisabledBundleIDs"
    }

    private let defaults: UserDefaults

    /// Opt-in: persist recent typing locally (encrypted) to personalize completions. OFF by default.
    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// Opt-in: include clipboard text in the prompt. OFF by default.
    var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) }
    }

    /// Opt-in: include on-screen / OCR context in the prompt. OFF by default.
    var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: Key.ocrEnabled) }
    }

    var completionLength: CompletionLength {
        didSet { defaults.set(completionLength.rawValue, forKey: Key.completionLength) }
    }

    /// Chosen GGUF filename in the Models directory, or `nil` to use the app default.
    var selectedModelFilename: String? {
        didSet { defaults.set(selectedModelFilename, forKey: Key.selectedModelFilename) }
    }

    /// Bundle identifiers the user has turned completions off for.
    var perAppDisabled: Set<String> {
        didSet { defaults.set(Array(perAppDisabled).sorted(), forKey: Key.perAppDisabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        self.clipboardEnabled = defaults.bool(forKey: Key.clipboardEnabled)
        self.ocrEnabled = defaults.bool(forKey: Key.ocrEnabled)
        self.completionLength = (defaults.string(forKey: Key.completionLength))
            .flatMap(CompletionLength.init(rawValue:)) ?? .medium
        self.selectedModelFilename = defaults.string(forKey: Key.selectedModelFilename)
        self.perAppDisabled = Set(defaults.stringArray(forKey: Key.perAppDisabled) ?? [])
    }

    func setApp(_ bundleIdentifier: String, enabled: Bool) {
        if enabled {
            perAppDisabled.remove(bundleIdentifier)
        } else {
            perAppDisabled.insert(bundleIdentifier)
        }
    }

    func isAppEnabled(_ bundleIdentifier: String) -> Bool {
        !perAppDisabled.contains(bundleIdentifier)
    }
}
