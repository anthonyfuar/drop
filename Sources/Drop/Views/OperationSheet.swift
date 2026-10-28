import SwiftUI

struct OperationSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var run: OperationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(statusText).foregroundStyle(.secondary)
                }
            }

            if let msg = run.resultMessage {
                Text(msg)
                    .font(.title3.weight(.medium))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            if run.steps.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(run.steps) { s in
                            HStack(spacing: 8) {
                                stepIcon(s.status).frame(width: 16)
                                Text(s.package.name).lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            DisclosureGroup(tr("Technical details", "Detalles técnicos"), isExpanded: Binding(get: { run.showLog || (run.finished && run.failedCount > 0) }, set: { run.showLog = $0 })) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(run.log.trimmingCharacters(in: .newlines))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(minHeight: 160, maxHeight: 260)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .onChange(of: run.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
            HStack {
                if run.running { ProgressView().controlSize(.small) }
                Spacer()
                if run.finished && run.adminRetryable {
                    Button(tr("Retry with Touch ID or password", "Reintentar con Touch ID o contraseña")) { store.retryAsAdmin() }
                }
                Button(run.finished ? tr("Done", "Listo") : tr("Working…", "Trabajando…")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!run.finished)
            }
        }
        .padding(22)
        .frame(width: 600)
        .frame(minHeight: 260)
        .interactiveDismissDisabled(run.running)
    }

    private var statusText: String {
        if run.running {
            return run.steps.count > 1 ? tr("Working… \(run.doneCount) of \(run.steps.count)", "Trabajando… \(run.doneCount) de \(run.steps.count)") : tr("Working…", "Trabajando…")
        }
        if !run.finished { return tr("Getting ready…", "Preparando…") }
        if run.failedCount == 0 { return tr("Finished successfully", "Terminado correctamente") }
        if run.adminRetryable { return tr("Administrator permission is needed to finish", "Hace falta permiso de administrador para terminar") }
        if run.steps.allSatisfy({ $0.status == .cancelled }) { return tr("Cancelled", "Cancelado") }
        return tr("\(run.failedCount) could not finish. Check the details.", "\(run.failedCount) no se pudieron completar. Revisa los detalles.")
    }

    @ViewBuilder
    private var statusIcon: some View {
        Group {
            if run.running {
                ProgressView().controlSize(.regular)
            } else if run.failedCount == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if run.adminRetryable {
                Image(systemName: "lock.circle.fill").foregroundStyle(.secondary)
            } else {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 34))
        .frame(width: 40, height: 40)
    }

    @ViewBuilder
    private func stepIcon(_ s: OperationStep.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .needsAdmin: Image(systemName: "lock.circle.fill").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}
