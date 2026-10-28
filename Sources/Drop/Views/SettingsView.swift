import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.english.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker(tr("Language", "Idioma"), selection: $language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                Picker(tr("Appearance", "Apariencia"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker(tr("Mark as unused after", "Marcar como sin usar después de"), selection: $store.unusedDays) {
                    ForEach([30, 60, 90, 180, 365], id: \.self) { days in
                        Text(tr("\(days) days", "\(days) días")).tag(days)
                    }
                }
                Toggle(tr("Show dependencies", "Mostrar dependencias"), isOn: $store.showDependencies)
            } footer: {
                Text(tr("Dependencies are things installed automatically because something else needs them.",
                        "Las dependencias son cosas que se instalaron solas porque otra cosa las necesita."))
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(store.maintenanceCommands(), id: \.0) { label, cmd in
                    LabeledContent(label) {
                        Button(tr("Run", "Ejecutar")) { store.runMaintenance(label, cmd) }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text(tr("Maintenance", "Mantenimiento"))
            }
            Section {
                LabeledContent(tr("Version", "Versión"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text(tr("Drop works entirely on your Mac. Nothing is uploaded anywhere.", "Drop funciona por completo en tu Mac. No se sube nada a ningún sitio."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 520)
    }
}
