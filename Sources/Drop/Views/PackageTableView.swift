import SwiftUI

struct PackageTableView: View {
    @Environment(Store.self) private var store
    @State private var sortOrder = [KeyPathComparator(\PackageRow.name, comparator: .localizedStandard)]

    var body: some View {
        @Bindable var store = store
        let rows = store.visibleRows.sorted(using: sortOrder)
        VStack(spacing: 0) {
            banner
            Table(rows, selection: $store.selection, sortOrder: $sortOrder) {
                TableColumn(tr("Name", "Nombre"), value: \.name, comparator: .localizedStandard) { r in
                    HStack(spacing: 7) {
                        Text(r.name)
                            .foregroundStyle(r.package.isDependency ? .secondary : .primary)
                            .lineLimit(1)
                        if r.package.isDependency {
                            Text(tr("dependency", "dependencia"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                .help(tr("Installed automatically because something else needs it", "Se instaló solo porque otra cosa lo necesita"))
                        }
                    }
                    .help(r.package.summary ?? r.name)
                }
                .width(min: 180, ideal: 280)

                TableColumn(tr("Version", "Versión"), value: \.version, comparator: .localizedStandard) { r in
                    Text(r.version == "?" ? "—" : r.version).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 100)

                TableColumn(tr("New version", "Nueva versión"), value: \.latestKey, comparator: .localizedStandard) { r in
                    if r.package.isOutdated, let l = r.package.latest {
                        Text(l)
                            .foregroundStyle(Color.dropAccent)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .width(min: 70, ideal: 110)

                TableColumn(tr("Source", "Origen"), value: \.sourceKey) { r in
                    Text(r.package.context.map { "\(r.package.source.name) · \($0)" } ?? r.package.source.name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 160)

                TableColumn(tr("Size", "Tamaño"), value: \.sizeKey) { r in
                    Text(Sizes.format(r.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)

                TableColumn(tr("Last used", "Último uso"), value: \.lastUsedKey) { r in
                    Text(Sizes.relative(r.lastUsed))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 100)

                TableColumn(tr("Location", "Ubicación"), value: \.pathKey) { r in
                    Text(r.package.path?.abbreviatingHome ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.tertiary)
                        .help(r.package.path ?? "")
                }
                .width(min: 120, ideal: 280)
            }
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: Package.ID.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                if let p = store.packages.first(where: { ids.contains($0.id) }) { store.reveal(p) }
            }
            .onDeleteCommand { store.request(.remove, store.selectedPackages) }
            .overlay { emptyState(rows.isEmpty) }
            statusBar(rows)
        }
        .onChange(of: store.sidebar, initial: true) { _, _ in applyDefaultSort() }
        .onChange(of: store.storageAscending) { _, _ in applyDefaultSort() }
    }

    private func applyDefaultSort() {
        switch store.sidebar {
        case .storage: sortOrder = [KeyPathComparator(\PackageRow.sizeKey, order: store.storageAscending ? .forward : .reverse)]
        case .unused: sortOrder = [KeyPathComparator(\PackageRow.lastUsedKey, order: .forward)]
        default: sortOrder = [KeyPathComparator(\PackageRow.name, comparator: .localizedStandard)]
        }
    }

    @ViewBuilder
    private var banner: some View {
        @Bindable var store = store
        let rows = store.filtered(store.sidebar, applySearch: false)
        let total = Sizes.format(rows.reduce(Int64(0)) { $0 + (store.size(of: $1) ?? 0) })
        switch store.sidebar ?? .all {
        case .updates:
            let deps = rows.filter(\.isDependency).count
            Banner(text: tr("\(rows.count) items have a newer version. \(rows.count - deps) you installed, \(deps) came in as dependencies.",
                            "\(rows.count) elementos tienen una versión más nueva. \(rows.count - deps) los instalaste tú y \(deps) llegaron como dependencias."))
        case .unused:
            Banner(text: tr("\(rows.count) items, \(total) in all, have not been opened in \(store.unusedDays) days.",
                            "\(rows.count) elementos, \(total) en total, no se han abierto en \(store.unusedDays) días."))
        case .storage:
            let top = rows.sorted { (store.size(of: $0) ?? 0) > (store.size(of: $1) ?? 0) }.prefix(5)
            let topSize = Sizes.format(top.reduce(Int64(0)) { $0 + (store.size(of: $1) ?? 0) })
            Banner(text: tr("\(rows.count) items use \(total). The five largest take \(topSize).",
                            "\(rows.count) elementos ocupan \(total). Los cinco más grandes suman \(topSize).")) {
                Picker("", selection: $store.storageAscending) {
                    Text(tr("Largest first", "Más grande primero")).tag(false)
                    Text(tr("Smallest first", "Más pequeño primero")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        case .all:
            Banner(text: tr("\(rows.count) items from \(Set(rows.map(\.source.id)).count) sources, \(total) on disk.",
                            "\(rows.count) elementos de \(Set(rows.map(\.source.id)).count) orígenes, \(total) en disco."))
        case .deepScan:
            Banner(text: tr("\(rows.count) system-level items and leftovers from sudo, \(total) in all.",
                            "\(rows.count) elementos del sistema y restos de sudo, \(total) en total.")) {
                Button(tr("Scan again", "Volver a escanear")) { store.runDeepScan() }.controlSize(.small)
            }
        case .group(let g):
            let sources = store.sources(in: g)
            let selected = sources.first { $0.id == store.sourceFilter }
            Banner(text: groupSummary(g, selected: selected)) {
                if sources.count > 1 {
                    Picker("", selection: $store.sourceFilter) {
                        Text(tr("All", "Todo")).tag(String?.none)
                        Divider()
                        ForEach(sources) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        default:
            EmptyView()
        }
    }

    private func groupSummary(_ g: SourceGroup, selected: SourceInfo?) -> String {
        let all = store.filtered(.group(g), applySearch: false)
        if let selected {
            let mine = all.filter { $0.source.id == selected.id }
            let size = Sizes.format(mine.reduce(Int64(0)) { $0 + (store.size(of: $1) ?? 0) })
            return "\(selected.name): " + tr("\(mine.count) items, \(size).", "\(mine.count) elementos, \(size).")
        }
        let parts = store.sources(in: g).map { s in "\(s.name) \(all.filter { $0.source.id == s.id }.count)" }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<Package.ID>) -> some View {
        let pkgs = store.packages.filter { ids.contains($0.id) }
        if !pkgs.isEmpty {
            let src = pkgs.first?.source
            ForEach([PackageAction.update, .repair], id: \.self) { a in
                if pkgs.contains(where: { $0.commands[a] != nil }) {
                    Button { store.request(a, pkgs) } label: { Label(a.title(for: src), systemImage: a.symbol) }
                }
            }
            if pkgs.contains(where: { $0.commands[.remove] != nil }) {
                Divider()
                Button(role: .destructive) { store.request(.remove, pkgs) } label: {
                    Label(PackageAction.remove.title(for: src) + "…", systemImage: PackageAction.remove.symbol)
                }
            }
            Divider()
            if pkgs.count == 1, let p = pkgs.first {
                if p.path != nil {
                    Button(tr("Show in Finder", "Mostrar en Finder")) { store.reveal(p) }
                    Button(tr("Copy location", "Copiar ubicación")) { store.copy(p.path ?? "") }
                }
                Button(tr("Copy name", "Copiar nombre")) { store.copy(p.name) }
                if let url = p.homepage.flatMap(URL.init(string:)) {
                    Divider()
                    Link(tr("Open project website", "Abrir sitio del proyecto"), destination: url)
                }
            } else {
                Button(tr("Copy names", "Copiar nombres")) { store.copy(pkgs.map(\.name).joined(separator: "\n")) }
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ empty: Bool) -> some View {
        if empty {
            if store.isScanning && store.packages.isEmpty {
                ProgressView()
            } else if !store.search.isEmpty {
                ContentUnavailableView.search(text: store.search)
            } else if store.sidebar == .updates {
                ContentUnavailableView(tr("Everything is up to date", "Todo está al día"), systemImage: "checkmark.circle",
                                       description: Text(store.checkingUpdates > 0 ? tr("Still checking for new versions…", "Aún se buscan versiones nuevas…") : ""))
            } else if !store.isScanning {
                ContentUnavailableView(tr("Nothing here", "Nada por aquí"), systemImage: "shippingbox")
            }
        }
    }

    private func statusBar(_ rows: [PackageRow]) -> some View {
        let total = rows.reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) }
        let selected = store.selection.count
        return HStack(spacing: 6) {
            Text(tr("\(rows.count) items", "\(rows.count) elementos"))
            if total > 0 { Text("·"); Text(Sizes.format(total)) }
            if selected > 0 { Text("·"); Text(tr("\(selected) selected", "\(selected) seleccionados")) }
            Spacer()
            if store.isScanning || store.checkingUpdates > 0 {
                ProgressView().controlSize(.mini)
                Text(store.isScanning ? tr("Scanning…", "Escaneando…") : tr("Checking for updates…", "Buscando actualizaciones…"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}
