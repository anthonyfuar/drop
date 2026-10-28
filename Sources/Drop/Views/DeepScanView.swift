import SwiftUI

struct DeepScanView: View {
    @Environment(Store.self) private var store
    @State private var fullDiskAccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Deep Scan", "Escaneo profundo")).font(.title.weight(.semibold))
                    Text(tr("Checks system folders, leftovers from sudo, files with broken permissions, and projects in Desktop, Documents and Downloads. Nothing changes until you decide.",
                            "Revisa carpetas del sistema, restos de sudo, archivos con permisos rotos y proyectos en Escritorio, Documentos y Descargas. Nada cambia hasta que tú decidas."))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    row(title: tr("Full Disk Access", "Acceso total al disco"),
                        detail: tr("Optional. Lets Drop read Desktop, Documents, Downloads and app containers such as Docker's disk without macOS asking each time.",
                                   "Opcional. Permite leer Escritorio, Documentos, Descargas y contenedores de apps como el disco de Docker sin que macOS pregunte cada vez.")) {
                        if fullDiskAccess {
                            Text(tr("Allowed", "Permitido")).foregroundStyle(.secondary)
                        } else {
                            Button(tr("Open Settings", "Abrir Ajustes")) { store.openFullDiskAccessSettings() }
                        }
                    }
                    Divider().padding(.horizontal, 16)
                    row(title: tr("Administrator permission", "Permiso de administrador"),
                        detail: tr("macOS asks for Touch ID or your password so Drop can read system folders.",
                                   "macOS pide Touch ID o tu contraseña para que Drop pueda leer carpetas del sistema.")) {
                        if store.deepScanState == .scanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(tr("Start Deep Scan", "Iniciar escaneo profundo")) { store.runDeepScan() }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.dropAccent)
                        }
                    }
                }
                .card()

                if case .failed(let message) = store.deepScanState {
                    Text(message).font(.callout).foregroundStyle(Color.dropAccent)
                }
                if store.deepScanState == .scanning {
                    Text(tr("Scanning system folders. This can take a minute.", "Revisando carpetas del sistema. Puede tardar un minuto."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { fullDiskAccess = store.hasFullDiskAccess }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = store.hasFullDiskAccess
        }
    }

    private func row<Accessory: View>(title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(16)
    }
}
