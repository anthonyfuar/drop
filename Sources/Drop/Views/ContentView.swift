import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var showInspector = true

    private var current: SidebarItem { store.sidebar ?? .cleanup }

    private var showsTable: Bool {
        switch current {
        case .cleanup, .settings: return false
        case .deepScan:
            if case .done = store.deepScanState { return true }
            return false
        default: return true
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                switch current {
                case .cleanup: CleanupView()
                case .settings: SettingsView()
                case .deepScan where !showsTable: DeepScanView()
                default: PackageTableView()
                }
            }
            .inspector(isPresented: Binding(get: { showInspector && showsTable }, set: { if showsTable { showInspector = $0 } })) {
                InspectorView()
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
        .navigationTitle(title)
        .searchable(text: $store.search, placement: .toolbar, prompt: tr("Search", "Buscar"))
        .onChange(of: store.sidebar) { _, _ in store.sourceFilter = nil }
        .onChange(of: store.search) { _, new in
            if !new.isEmpty && !showsTable { store.sidebar = .all }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isScanning {
                    ProgressView().controlSize(.small).padding(.horizontal, 6)
                } else {
                    Button { Task { await store.scanAll() } } label: { Label(tr("Scan again", "Volver a escanear"), systemImage: "arrow.clockwise") }
                        .help(tr("Scan again (⌘R)", "Volver a escanear (⌘R)"))
                }
                if showsTable {
                    Button { showInspector.toggle() } label: { Label(tr("Details", "Detalles"), systemImage: "sidebar.right") }
                        .help(tr("Show or hide details", "Mostrar u ocultar detalles"))
                }
            }
        }
        .sheet(item: $store.operation) { run in
            OperationSheet(run: run)
        }
        .alert(confirmTitle, isPresented: Binding(get: { store.pendingConfirmation != nil }, set: { if !$0 { store.pendingConfirmation = nil } })) {
            if let c = store.pendingConfirmation {
                Button(c.action.title(for: c.packages.first?.source), role: c.action == .remove ? .destructive : nil) { store.confirm() }
                Button(tr("Cancel", "Cancelar"), role: .cancel) { store.pendingConfirmation = nil }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var title: String {
        switch current {
        case .cleanup: tr("Cleanup", "Limpieza")
        case .updates: tr("Updates", "Actualizaciones")
        case .unused: tr("Unused", "Sin usar")
        case .storage: tr("Storage", "Almacenamiento")
        case .all: tr("Everything", "Todo")
        case .deepScan: tr("Deep Scan", "Escaneo profundo")
        case .settings: tr("Settings", "Ajustes")
        case .group(let g): g.title
        }
    }

    private var confirmTitle: String {
        guard let c = store.pendingConfirmation else { return "" }
        let verb = c.action.title(for: c.packages.first?.source)
        return c.packages.count == 1 ? "\(verb) “\(c.packages[0].name)”?" : tr("\(verb) \(c.packages.count) items?", "¿\(verb) \(c.packages.count) elementos?")
    }

    private var confirmMessage: String {
        guard let c = store.pendingConfirmation else { return "" }
        var parts: [String] = []
        switch c.action {
        case .remove:
            parts.append(c.packages.allSatisfy { $0.source.group == .caches }
                ? tr("These temporary files will be deleted. Your tools will recreate them when needed.",
                     "Se borrarán estos archivos temporales. Tus herramientas los volverán a crear cuando hagan falta.")
                : tr("It will be removed from your Mac. You can install it again whenever you want.",
                     "Se quitará de tu Mac. Podrás volver a instalarlo cuando quieras."))
        case .update: parts.append(tr("The newest version will be installed.", "Se instalará la versión más reciente."))
        case .repair: parts.append(tr("The same version will be reinstalled to fix damaged files.", "Se reinstalará la misma versión para arreglar archivos dañados."))
        }
        let warnings = c.packages.compactMap { p in p.warning.map { "⚠︎ \(c.packages.count > 1 ? p.name + ": " : "")\($0)" } }
        if !warnings.isEmpty { parts.append(warnings.prefix(4).joined(separator: "\n")) }
        if c.packages.contains(where: { $0.commands[c.action]?.needsAdmin == true }) {
            parts.append(tr("macOS will ask for Touch ID or your password.", "macOS pedirá Touch ID o tu contraseña."))
        }
        let cmds = c.packages.prefix(3).compactMap { $0.commands[c.action]?.script }
        parts.append(cmds.joined(separator: "\n") + (c.packages.count > 3 ? tr("\n…and \(c.packages.count - 3) more", "\n…y \(c.packages.count - 3) más") : ""))
        return parts.joined(separator: "\n\n")
    }
}

extension OperationRun: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
