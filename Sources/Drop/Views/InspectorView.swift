import SwiftUI

struct InspectorView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let selected = store.selectedPackages
        Group {
            if selected.count == 1, let p = selected.first {
                PackageDetail(package: p)
            } else if selected.count > 1 {
                MultiDetail(packages: selected)
            } else {
                ContentUnavailableView(tr("Nothing selected", "Sin selección"), systemImage: "sidebar.right", description: Text(tr("Pick an item to see where it lives, how big it is and what you can do.", "Elige un elemento para ver dónde está, cuánto ocupa y qué puedes hacer.")))
            }
        }
    }
}

private struct ActionButtons: View {
    @Environment(Store.self) private var store
    let packages: [Package]

    var body: some View {
        let src = packages.first?.source
        HStack(spacing: 8) {
            if packages.contains(where: { $0.commands[.update] != nil }) {
                Button { store.request(.update, packages) } label: {
                    Label(PackageAction.update.title(for: src), systemImage: PackageAction.update.symbol).frame(maxWidth: .infinity)
                }
                .tint(packages.contains(where: \.isOutdated) ? Color.dropAccent : nil)
                .buttonStyle(packages.contains(where: \.isOutdated) ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            }
            if packages.contains(where: { $0.commands[.repair] != nil }) {
                Button { store.request(.repair, packages) } label: {
                    Label(PackageAction.repair.title(for: src), systemImage: PackageAction.repair.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        if packages.contains(where: { $0.commands[.remove] != nil }) {
            Button(role: .destructive) { store.request(.remove, packages) } label: {
                Label(PackageAction.remove.title(for: src) + (packages.count > 1 ? " (\(packages.count))" : ""), systemImage: PackageAction.remove.symbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
        }
    }
}

struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct PackageDetail: View {
    @Environment(Store.self) private var store
    let package: Package

    var body: some View {
        let p = package
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(.title2.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                    Text(p.context.map { "\(p.source.name) · \($0)" } ?? p.source.name)
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let s = p.summary, !s.isEmpty {
                    Text(s).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let blurb = p.source.blurb {
                    Label { Text(.init(blurb)) } icon: { Image(systemName: "info.circle") }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if p.isOutdated, let l = p.latest {
                    Label(tr("New version available: \(l)", "Hay una versión nueva: \(l)"), systemImage: "arrow.up.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.dropAccent)
                }

                if let w = p.warning {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .symbolRenderingMode(.multicolor)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(spacing: 8) { ActionButtons(packages: [p]) }

                Divider()

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    info(tr("Version", "Versión"), p.version)
                    if let l = p.latest, p.isOutdated { info(tr("New version", "Nueva versión"), l) }
                    info(tr("Size", "Tamaño"), Sizes.format(store.size(of: p)))
                    if let used = store.lastUsed(p) {
                        info(tr("Last used", "Último uso"), Sizes.relative(used) + tr(" (approx.)", " (aprox.)"))
                    }
                    if let mod = store.lastModified(p) {
                        info(tr("Installed or updated", "Instalado o actualizado"), mod.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.current.locale)))
                    }
                    info(tr("Type", "Tipo"), p.isDependency ? tr("Dependency (installed because something else needs it)", "Dependencia (se instaló porque otra cosa la necesita)") : tr("Installed directly", "Instalado directamente"))
                    ForEach(Array(p.details.enumerated()), id: \.offset) { _, d in info(d.0, d.1) }
                }

                if let path = p.path {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Location", "Ubicación")).font(.caption).foregroundStyle(.secondary)
                        Text(path).font(.callout.monospaced()).textSelection(.enabled)
                        HStack {
                            Button(tr("Show in Finder", "Mostrar en Finder")) { store.reveal(p) }
                            Button(tr("Copy", "Copiar")) { store.copy(path) }
                        }
                        .controlSize(.small)
                    }
                }

                if let url = p.homepage.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { Label(url.host() ?? url.absoluteString, systemImage: "safari") }
                        .font(.callout)
                }

                let cmds = PackageAction.allCases.compactMap { a in p.commands[a].map { (a, $0) } }
                if !cmds.isEmpty {
                    Divider()
                    DisclosureGroup(tr("Commands Drop will run", "Comandos que usará Drop")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(cmds, id: \.0) { a, c in
                                CommandBox(label: a.title(for: p.source), command: c)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func info(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled).lineLimit(6)
        }
        .font(.callout)
    }
}

private struct CommandBox: View {
    @Environment(Store.self) private var store
    let label: String
    let command: ShellCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                if command.needsAdmin {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help(tr("Asks for Touch ID or your password", "Pide Touch ID o tu contraseña"))
                }
                Spacer()
                Button { store.copy(command.script) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(tr("Copy command", "Copiar comando"))
            }
            Text(command.script)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(5)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct MultiDetail: View {
    @Environment(Store.self) private var store
    let packages: [Package]

    var body: some View {
        let total = packages.reduce(Int64(0)) { $0 + (store.size(of: $1) ?? 0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tr("\(packages.count) selected", "\(packages.count) seleccionados")).font(.title3.weight(.semibold))
                Text(tr("Using \(Sizes.format(total))", "Ocupan \(Sizes.format(total))")).foregroundStyle(.secondary)
                VStack(spacing: 8) { ActionButtons(packages: packages) }
                Divider()
                ForEach(packages.prefix(60)) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(Sizes.format(store.size(of: p))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if packages.count > 60 { Text(tr("…and \(packages.count - 60) more", "…y \(packages.count - 60) más")).foregroundStyle(.secondary).font(.callout) }
            }
            .padding(16)
        }
    }
}
