import Foundation

@main
struct SettingsTests {
    static func main() {
        let suite = "voice-enhancer-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(label)") }
        }
        let store = SettingsStore(defaults: defaults)
        expect(store.load().working == .factory(.natural), "missing state loads Natural")
        var custom = WorkingSettings.factory(.broadcast)
        custom.isCustom = true; custom.compThresholdDb = -35; custom.deesserThresholdDb = -40; custom.isEnabled = false
        let document = SettingsDocument(working: custom, custom: custom)
        store.save(document)
        expect(SettingsStore(defaults: defaults).load() == document, "Custom base, thresholds and bypass survive restart")
        let factory = SettingsDocument(working: .factory(.warm), custom: custom)
        store.save(factory)
        expect(store.load().custom == custom && store.load().working.basePreset == 3, "factory selection retains last Custom")
        defaults.set(Data("invalid".utf8), forKey: SettingsStore.key)
        expect(store.load() == document, "invalid current document recovers prior valid state")
        expect(defaults.data(forKey: SettingsStore.key + ".rejected") != nil && store.recoveryNotice != nil,
               "invalid bytes retained and recovery reported")
        defaults.removePersistentDomain(forName: suite)
        defaults.set(4, forKey: "tech.aheadly.voice-enhancer.preset")
        defaults.set(Float(-32), forKey: "tech.aheadly.voice-enhancer.customCompThresholdDb")
        defaults.set(Float(-41), forKey: "tech.aheadly.voice-enhancer.customDeesserThresholdDb")
        defaults.set(false, forKey: "tech.aheadly.voice-enhancer.processingEnabled")
        let legacy = store.load()
        expect(legacy.working.isCustom && legacy.working.basePreset == 0 && legacy.working.baseWasRecovered,
               "legacy Custom uses documented Natural fallback")
        expect(legacy.working.compThresholdDb == -32 && legacy.working.deesserThresholdDb == -41 && !legacy.working.isEnabled,
               "legacy tuning and false bypass restored rather than treated as missing")
        expect(defaults.object(forKey: "tech.aheadly.voice-enhancer.preset") != nil, "legacy keys retained")
        defaults.set(Float.nan, forKey: "tech.aheadly.voice-enhancer.customCompThresholdDb")
        expect(store.load().working == .factory(.natural), "invalid legacy numeric value recovers safely")
        defaults.removePersistentDomain(forName: suite)
        var unsupported = document; unsupported.version = 99
        defaults.set(try! JSONEncoder().encode(unsupported), forKey: SettingsStore.key)
        expect(store.load().working == .factory(.natural), "unsupported version is not interpreted as current state")
        let preserved = defaults.data(forKey: SettingsStore.key)
        var invalid = custom; invalid.basePreset = 4
        store.save(SettingsDocument(working: invalid))
        expect(defaults.data(forKey: SettingsStore.key) == preserved, "invalid document cannot overwrite preserved state")
        print("Settings: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
