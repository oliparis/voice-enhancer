import Foundation

/// Current UI controls plus their factory base. Custom is an app concept;
/// factory IDs 0–3 remain the only DSP preset identifiers. Later complete-chain
/// documents can migrate this version without guessing the Custom base.
struct WorkingSettings: Codable, Equatable {
    var basePreset: Int
    var isCustom: Bool
    var compThresholdDb: Float
    var deesserThresholdDb: Float
    var isEnabled: Bool
    var baseWasRecovered: Bool = false

    static func factory(_ preset: Preset) -> WorkingSettings {
        let base = preset.isFactoryPreset ? preset : .natural
        return WorkingSettings(basePreset: base.rawValue, isCustom: false,
            compThresholdDb: base.defaultCompThresholdDb,
            deesserThresholdDb: base.defaultDeesserThresholdDb, isEnabled: true)
    }

    var isValid: Bool {
        (0...3).contains(basePreset) && compThresholdDb.isFinite && deesserThresholdDb.isFinite &&
        (-40 ... -10).contains(compThresholdDb) && (-48 ... -16).contains(deesserThresholdDb)
    }
}

struct SettingsDocument: Codable, Equatable {
    var version = 1
    var working = WorkingSettings.factory(.natural)
    var custom: WorkingSettings?
    var isValid: Bool { version == 1 && working.isValid && (custom?.isValid ?? true) }
}
