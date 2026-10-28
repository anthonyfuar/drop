import SwiftUI

struct CleanupView: View {
    @Environment(Store.self) private var store
    @State private var showOptional = false

    var body: some View {
        let items = store.visibleCleanItems
        let safe = items.filter { $0.safety == .safe }
        let optional = items.filter { $0.safety == .optional }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let msg = store.lastCleanup {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                if !store.hasScanned {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(tr("Looking at everything installed on your Mac…", "Revisando todo lo instalado en tu Mac…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if items.isEmpty {
                    ContentUnavailableView(tr("All clean", "Todo limpio"), systemImage: "checkmark.seal",
                                           description: Text(tr("There is nothing temporary to delete right now.", "No hay archivos temporales que borrar.")))
                        .frame(minHeight: 260)
                } else {
                    section(tr("Safe to delete", "Seguro de borrar"),
                            tr("Your tools rebuild these on their own when needed.", "Tus herramientas los vuelven a crear solas cuando hacen falta."),
                            safe, safety: .safe)
                    if !optional.isEmpty {
                        DisclosureGroup(isExpanded: $showOptional) {
                            section(nil, tr("These come back only after downloading them again. Unchecked by default.",
                                            "Solo vuelven si los descargas de nuevo. Desmarcados por defecto."),
                                    optional, safety: .optional)
                                .padding(.top, 8)
                        } label: {
                            Text(tr("Optional (\(optional.count))", "Opcional (\(optional.count))")).font(.headline)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Safe Cleanup", "Limpieza segura")).font(.title.weight(.semibold))
                Text(.init(tr("Deletes only caches and temporary files. **Nothing gets uninstalled.**",
                              "Borra solo cachés y archivos temporales. **No se desinstala nada.**")))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if store.measuring > 0 { ProgressView().controlSize(.mini) }
                    Text(Sizes.format(store.cleanSelectedSize))
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Button {
                    store.runCleanup()
                } label: {
                    Label(tr("Clean Safely", "Limpiar de forma segura"), systemImage: "trash").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.dropAccent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.hasScanned || store.cleanSelectedSize == 0 && !store.visibleCleanItems.contains(where: { store.isCleanSelected($0) }))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String?, _ subtitle: String, _ items: [CleanItem], safety: CleanSafety) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(.headline) }
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                let all = items.allSatisfy(store.isCleanSelected)
                Button(all ? tr("Deselect all", "Desmarcar todo") : tr("Select all", "Marcar todo")) {
                    store.setCleanSelected(safety, !all)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.callout)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 44) }
                    CleanRow(item: item)
                }
            }
            .card()
        }
    }
}

private struct CleanRow: View {
    @Environment(Store.self) private var store
    let item: CleanItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { store.isCleanSelected(item) }, set: { store.setCleanSelected(item, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).font(.body.weight(.medium))
                    if item.command.needsAdmin {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help(tr("Asks for Touch ID or your password", "Pide Touch ID o tu contraseña"))
                    }
                }
                Text(item.explanation).font(.callout).foregroundStyle(.secondary)
                if item.paths.isEmpty {
                    Text(item.command.script).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                } else {
                    ForEach(item.paths.prefix(3), id: \.self) { path in
                        Button { store.reveal(path: path) } label: {
                            Text(path.abbreviatingHome)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Show in Finder", "Mostrar en Finder"))
                    }
                    if item.paths.count > 3 {
                        Text(tr("and \(item.paths.count - 3) more", "y \(item.paths.count - 3) más"))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 12)
            Text(item.id == "broken-links" ? tr("\(item.paths.count) links", "\(item.paths.count) enlaces") : item.size.map { Sizes.format($0) } ?? (item.paths.isEmpty ? "" : "…"))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { store.setCleanSelected(item, !store.isCleanSelected(item)) }
    }
}
