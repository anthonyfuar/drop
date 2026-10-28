import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.english.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        Window("Drop", id: "main") {
            ContentView()
                .environment(store)
                .id(language)
                .frame(minWidth: 940, minHeight: 600)
                .task {
                    AppAppearance.apply(appearance)
                    await store.start()
                }
                .onChange(of: appearance) { _, new in AppAppearance.apply(new) }
                .onChange(of: language) { _, _ in
                    Task { await store.scanAll() }
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(tr("Safe Cleanup", "Limpieza segura")) { store.sidebar = .cleanup }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(tr("Deep Scan…", "Escaneo profundo…")) { store.sidebar = .deepScan }
            }
            CommandGroup(after: .toolbar) {
                Button(tr("Scan Again", "Volver a escanear")) { Task { await store.scanAll() } }
                    .keyboardShortcut("r")
                    .disabled(store.isScanning)
            }
            CommandMenu(tr("Item", "Elemento")) {
                Button(tr("Update", "Actualizar")) { store.request(.update, store.selectedPackages) }
                    .keyboardShortcut("u")
                    .disabled(!store.selectedPackages.contains { $0.commands[.update] != nil })
                Button(tr("Repair", "Reparar")) { store.request(.repair, store.selectedPackages) }
                    .disabled(!store.selectedPackages.contains { $0.commands[.repair] != nil })
                Divider()
                Button(tr("Uninstall…", "Desinstalar…")) { store.request(.remove, store.selectedPackages) }
                    .keyboardShortcut(.delete)
                    .disabled(!store.selectedPackages.contains { $0.commands[.remove] != nil })
                Divider()
                Button(tr("Show in Finder", "Mostrar en Finder")) { store.selectedPackages.first.map(store.reveal) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.selectedPackages.first?.path == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .id(language)
                .frame(width: 520, height: 520)
        }
    }
}
