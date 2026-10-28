import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    static let storageKey = "appLanguage"

    var locale: Locale { Locale(identifier: self == .spanish ? "es" : "en") }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .english
    }
}

func tr(_ en: String, _ es: String) -> String {
    AppLanguage.current == .spanish ? es : en
}
