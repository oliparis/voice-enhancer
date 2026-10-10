import Foundation

enum SettingsRecoveryNotice {
    case savedInvalid, legacyInvalid, legacyCustomBase

    func text(language: AppLanguage) -> String {
        let key: LocalizedStrings.Key
        switch self {
        case .savedInvalid: key = .savedSettingsInvalid
        case .legacyInvalid: key = .legacySettingsInvalid
        case .legacyCustomBase: key = .legacyCustomRecovered
        }
        return LocalizedStrings.text(key, language: language)
    }
}

/// Versioned single-document persistence. Keep a prior valid document and retain
/// rejected bytes/legacy keys so recovery does not destroy future migration data.
final class SettingsStore {
    static let key = "tech.aheadly.voice-enhancer.workingSettings.v1"
    private let defaults: UserDefaults
    private(set) var recoveryNotice: SettingsRecoveryNotice?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SettingsDocument {
        if let data = defaults.data(forKey: Self.key) {
            if let document = decode(data) { return document }
            defaults.set(data, forKey: Self.key + ".rejected")
            recoveryNotice = .savedInvalid
            if let backup = defaults.data(forKey: Self.key + ".backup"), let document = decode(backup) { return document }
            return SettingsDocument()
        }
        // Optional compatibility reader for wondervip-only defaults. They did
        // not record Custom's base; document Natural as the recovery fallback.
        let raw = defaults.integer(forKey: "tech.aheadly.voice-enhancer.preset")
        let preset = Preset(rawValue: raw) ?? .natural
        var working = WorkingSettings.factory(preset)
        let prefix = "tech.aheadly.voice-enhancer."
        let compKey = prefix + (preset == .custom ? "customCompThresholdDb" : "compThresholdDb")
        let deessKey = prefix + (preset == .custom ? "customDeesserThresholdDb" : "deesserThresholdDb")
        if defaults.object(forKey: compKey) != nil { working.compThresholdDb = defaults.float(forKey: compKey) }
        if defaults.object(forKey: deessKey) != nil { working.deesserThresholdDb = defaults.float(forKey: deessKey) }
        if defaults.object(forKey: prefix + "processingEnabled") != nil {
            working.isEnabled = defaults.bool(forKey: prefix + "processingEnabled")
        }
        working.isCustom = preset == .custom || working.compThresholdDb != preset.defaultCompThresholdDb ||
            working.deesserThresholdDb != preset.defaultDeesserThresholdDb
        working.baseWasRecovered = preset == .custom
        if !working.isValid {
            recoveryNotice = .legacyInvalid
            return SettingsDocument()
        }
        if working.baseWasRecovered {
            recoveryNotice = .legacyCustomBase
        }
        return SettingsDocument(working: working, custom: working.isCustom ? working : nil)
    }

    func save(_ document: SettingsDocument) {
        guard document.isValid, let data = try? JSONEncoder().encode(document) else { return }
        if let previous = defaults.data(forKey: Self.key), decode(previous) != nil {
            defaults.set(previous, forKey: Self.key + ".backup")
        }
        defaults.set(data, forKey: Self.key)
    }

    private func decode(_ data: Data) -> SettingsDocument? {
        guard let document = try? JSONDecoder().decode(SettingsDocument.self, from: data), document.isValid else { return nil }
        return document
    }
}
