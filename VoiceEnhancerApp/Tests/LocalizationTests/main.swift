import Foundation
import SwiftUI

@main
struct LocalizationTests {
    static func main() {
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(label)") }
        }
        func placeholders(_ text: String) -> [String] {
            let expression = try! NSRegularExpression(pattern: "%[@df]")
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for language in AppLanguage.allCases {
            for key in LocalizedStrings.Key.allCases {
                let value = LocalizedStrings.table[language]?[key]
                expect(value != nil && !(value?.isEmpty ?? true), "\(language.rawValue) has \(key.rawValue)")
                expect(placeholders(value ?? "") == placeholders(LocalizedStrings.text(key, language: .english)),
                       "\(language.rawValue) preserves \(key.rawValue) placeholders")
            }
            expect(!LocalizedStrings.text(.speakNow, language: language, 3).contains("%d"), "countdown formats in \(language.rawValue)")
            expect(LocalizedStrings.text(.errorPrefix, language: language, "example").contains("example"), "error detail preserved")
        }
        expect(AppLanguage.preferred(["de-DE", "es-MX"]) == .spanish, "unsupported locale skips to supported preference")
        expect(AppLanguage.preferred(["xx"]) == .english, "unsupported preferences fall back to English")
        expect(AppLanguage.preferred(["zh-Hans-CN"]) == .chineseSimplified, "language region selects supported Chinese")
        expect(AppLanguage.arabic.layoutDirection == .rightToLeft && AppLanguage.english.layoutDirection == .leftToRight,
               "Arabic layout is RTL without changing audio settings")
        print("Localization: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
