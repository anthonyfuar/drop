import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let storageKey = "appAppearance"

    var title: String {
        switch self {
        case .system: tr("Automatic", "Automático")
        case .light: tr("Light", "Claro")
        case .dark: tr("Dark", "Oscuro")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func apply(_ raw: String) {
        NSApp.appearance = (AppAppearance(rawValue: raw) ?? .system).nsAppearance
    }
}
