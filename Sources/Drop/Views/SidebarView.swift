import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text("Drop").font(.headline)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)

                    row(tr("Cleanup", "Limpieza"), "trash", .cleanup,
                        badge: store.safeCleanTotal > 0 ? Sizes.format(store.safeCleanTotal) : nil)
                    row(tr("Updates", "Actualizaciones"), "arrow.up.circle", .updates, badge: count(.updates))
                    row(tr("Unused", "Sin usar"), "clock", .unused, badge: count(.unused))
                    row(tr("Storage", "Almacenamiento"), "internaldrive", .storage)
                    row(tr("Everything", "Todo"), "list.bullet", .all)
                    row(tr("Deep Scan", "Escaneo profundo"), "lock", .deepScan, badge: deepBadge)

                    Text(tr("Library", "Biblioteca"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 20)
                        .padding(.bottom, 4)

                    ForEach(store.groups, id: \.self) { group in
                        row(group.title, group.symbol, .group(group))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider()
            HStack(spacing: 8) {
                row(tr("Settings", "Ajustes"), "gearshape", .settings)
                if store.isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func count(_ item: SidebarItem) -> String? {
        let n = store.count(item)
        return n > 0 ? "\(n)" : nil
    }

    private var deepBadge: String? {
        if case .done = store.deepScanState, store.count(.deepScan) > 0 { return "\(store.count(.deepScan))" }
        return nil
    }

    private func row(_ title: String, _ symbol: String, _ item: SidebarItem, badge: String? = nil) -> some View {
        let selected = store.sidebar == item
        return Button {
            store.sidebar = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let badge {
                    Text(badge)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
