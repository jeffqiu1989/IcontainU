import Foundation

/// In-app language override for the 中英文 switcher.
///
/// Writes `AppleLanguages` so the next launch resolves localized strings against
/// the chosen locale; `.system` clears the override to follow the OS. A relaunch
/// is required for SwiftUI text to re-resolve - `Bundle`'s preferred-localization
/// lookup is read at process start and `LocalizedStringKey`/`String(localized:)`
/// results are effectively cached for the lifetime of the app, so a live switch
/// would leave most of the UI in the old language. The picker confirms via an
/// alert and offers to relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zhHans

    var id: String { rawValue }

    /// The language code written to `AppleLanguages`, or nil to follow the system.
    private var appleLanguagesCode: String? {
        switch self {
        case .system: nil
        case .en: "en"
        case .zhHans: "zh-Hans"
        }
    }

    /// Persisted selection, inferring from `AppleLanguages` as a fallback so a
    /// prior override still reads back correctly if the prefs key is absent.
    static var current: AppLanguage {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.key),
           let lang = AppLanguage(rawValue: raw) {
            return lang
        }
        if let first = defaults.stringArray(forKey: "AppleLanguages")?.first {
            if first.hasPrefix("zh-Hans") || first.hasPrefix("zh") { return .zhHans }
            if first.hasPrefix("en") { return .en }
        }
        return .system
    }

    /// Apply the selection: set or clear `AppleLanguages`, and persist the choice.
    func apply() {
        let defaults = UserDefaults.standard
        if let code = appleLanguagesCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.set(rawValue, forKey: AppLanguage.key)
    }

    /// Display name, localized in the currently-effective language.
    var localizedName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .en: String(localized: "English")
        case .zhHans: String(localized: "Simplified Chinese")
        }
    }

    private static let key = "IcontainU.language"
}
