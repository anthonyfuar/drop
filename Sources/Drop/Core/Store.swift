import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable {
    case cleanup, updates, unused, storage, all, deepScan, settings, group(SourceGroup)
}

struct OperationStep: Identifiable {
    let id = UUID()
    let package: Package
    let action: PackageAction
    let command: ShellCommand
    var status: Status = .pending
    enum Status { case pending, running, ok, failed, needsAdmin, cancelled }
}

@MainActor
@Observable
final class OperationRun {
    var title: String
    var steps: [OperationStep]
    var log = ""
    var running = false
    var finished = false
    var resultMessage: String?
    var showLog = false

    init(title: String, steps: [OperationStep]) {
        self.title = title
        self.steps = steps
    }

    var failedCount: Int { steps.filter { $0.status == .failed || $0.status == .needsAdmin }.count }
    var adminRetryable: Bool { steps.contains { $0.status == .needsAdmin } }
    var doneCount: Int { steps.filter { $0.status == .ok }.count }
}

struct CleanItem: Identifiable {
    let id: String
    let title: String
    let explanation: String
    let paths: [String]
    let command: ShellCommand
    let safety: CleanSafety
    var size: Int64?
}

enum DeepScanState: Equatable {
    case locked, scanning, done(Date), failed(String)
}

@MainActor
@Observable
final class Store {
    private(set) var env: ShellEnv?
    private var results: [Int: [Package]] = [:]
    private(set) var packages: [Package] = []
    private(set) var usage: [String: DiskInfo] = [:]
    private(set) var pendingScanners = 0
    private(set) var checkingUpdates = 0
    private(set) var measuring = 0
    private(set) var lastScanDuration: TimeInterval?
    private(set) var hasScanned = false
    private(set) var catalog: [CleanEntry] = []
    private(set) var cleanItems: [CleanItem] = []
    private(set) var deepScanState: DeepScanState = .locked
    private(set) var lastCleanup: String?
    private var cleanChoices: [String: Bool] = [:]
    private var scanStart = Date()
    private var scanGeneration = 0
    private let adminIndex = -1

    var sidebar: SidebarItem? = .cleanup
    var search = ""
    var selection = Set<Package.ID>()
    var operation: OperationRun?
    var pendingConfirmation: (action: PackageAction, packages: [Package])?
    var storageAscending = false
    var sourceFilter: String?

    var showDependencies: Bool {
        get { access(keyPath: \.showDependencies); return UserDefaults.standard.object(forKey: "showDependencies") as? Bool ?? true }
        set { withMutation(keyPath: \.showDependencies) { UserDefaults.standard.set(newValue, forKey: "showDependencies") } }
    }

    var unusedDays: Int {
        get { access(keyPath: \.unusedDays); return UserDefaults.standard.object(forKey: "unusedDays") as? Int ?? 90 }
        set { withMutation(keyPath: \.unusedDays) { UserDefaults.standard.set(newValue, forKey: "unusedDays") } }
    }

    var isScanning: Bool { pendingScanners > 0 }

    func start() async {
        if env == nil { env = await ShellEnv.resolve() }
        await scanAll()
    }

    func scanAll() async {
        guard let env else { return }
        scanGeneration += 1
        let gen = scanGeneration
        scanStart = Date()
        catalog = CacheCatalog.entries(env)
        pendingScanners = Registry.all.count
        if results[adminIndex] != nil {
            results[adminIndex] = nil
            deepScanState = .locked
        }
        await withTaskGroup(of: Void.self) { group in
            for (i, scanner) in Registry.all.enumerated() {
                group.addTask { await self.runScanner(i, scanner, env: env, generation: gen) }
            }
        }
        hasScanned = true
        rebuildCleanItems()
    }

    func rescan(sources: Set<String>) async {
        guard let env else { return }
        let indices = results.filter { i, pkgs in i >= 0 && pkgs.contains { sources.contains($0.source.id) } }.map(\.key)
        let gen = scanGeneration
        pendingScanners += indices.count
        await withTaskGroup(of: Void.self) { group in
            for i in indices {
                group.addTask { await self.runScanner(i, Registry.all[i], env: env, generation: gen) }
            }
        }
        catalog = CacheCatalog.entries(env)
        rebuildCleanItems()
    }

    nonisolated private func runScanner(_ i: Int, _ scanner: any Scanner, env: ShellEnv, generation: Int) async {
        let found = await scanner.scan(env)
        await MainActor.run {
            guard generation == self.scanGeneration else { return }
            self.results[i] = found
            self.rebuild()
            self.pendingScanners = max(0, self.pendingScanners - 1)
            if self.pendingScanners == 0 { self.lastScanDuration = Date().timeIntervalSince(self.scanStart) }
            self.measure(found.compactMap { $0.knownSize == nil ? $0.path : nil })
        }
        guard !found.isEmpty else { return }
        await MainActor.run { self.checkingUpdates += 1 }
        let latest = await scanner.latestVersions(env, found)
        await MainActor.run {
            self.checkingUpdates -= 1
            guard generation == self.scanGeneration, !latest.isEmpty, var current = self.results[i] else { return }
            for j in current.indices {
                if let l = latest[current[j].id], Version.normalize(l) != Version.normalize(current[j].version) { current[j].latest = l }
            }
            self.results[i] = current
            self.rebuild()
        }
    }

    private func rebuild() {
        packages = results.keys.sorted { ($0 < 0 ? Int.max : $0) < ($1 < 0 ? Int.max : $1) }.flatMap { results[$0] ?? [] }
        let ids = Set(packages.map(\.id))
        selection = selection.filter { ids.contains($0) }
    }

    private func measure(_ allPaths: [String], force: Bool = false) {
        let paths = Array(Set(allPaths)).filter { force || usage[$0] == nil }
        guard !paths.isEmpty else { return }
        measuring += 1
        Task.detached(priority: .utility) {
            await withTaskGroup(of: (String, DiskInfo?).self) { group in
                var it = paths.makeIterator()
                for _ in 0..<4 {
                    if let p = it.next() { group.addTask { (p, Sizes.measure(p)) } }
                }
                var batch: [String: DiskInfo] = [:]
                var lastFlush = Date()
                for await (p, info) in group {
                    if let info { batch[p] = info }
                    if let n = it.next() { group.addTask { (n, Sizes.measure(n)) } }
                    if Date().timeIntervalSince(lastFlush) > 0.5 {
                        let b = batch
                        await MainActor.run { self.usage.merge(b) { _, n in n } }
                        batch = [:]
                        lastFlush = Date()
                    }
                }
                let b = batch
                await MainActor.run {
                    self.usage.merge(b) { _, n in n }
                    self.measuring -= 1
                    self.refreshCleanSizes()
                }
            }
        }
    }

    func size(of p: Package) -> Int64? {
        p.knownSize ?? p.path.flatMap { usage[$0]?.size }
    }

    func lastUsed(_ p: Package) -> Date? {
        guard let path = p.path, let u = usage[path] else { return nil }
        return u.lastAccess ?? u.lastModified
    }

    func lastModified(_ p: Package) -> Date? { p.path.flatMap { usage[$0]?.lastModified } }

    var sources: [SourceInfo] {
        var seen = Set<String>()
        return packages.map(\.source).filter { seen.insert($0.id).inserted && $0.id != AdminScan.source.id }
    }

    private func isInventory(_ p: Package) -> Bool {
        p.source.group != .caches && p.source.id != Src.active.id && p.source.id != AdminScan.source.id
    }

    func count(_ item: SidebarItem) -> Int { filtered(item, applySearch: false).count }

    func filtered(_ item: SidebarItem?, applySearch: Bool = true) -> [Package] {
        var list: [Package]
        switch item ?? .cleanup {
        case .cleanup, .settings, .all: list = packages.filter(isInventory)
        case .updates: list = packages.filter(\.isOutdated)
        case .storage: list = packages.filter { isInventory($0) && (size(of: $0) ?? 0) > 0 }
        case .unused:
            let limit = Date().addingTimeInterval(-Double(unusedDays) * 86_400)
            list = packages.filter { isInventory($0) && (lastUsed($0).map { $0 < limit } ?? false) }
        case .deepScan: list = packages.filter { $0.source.id == AdminScan.source.id }
        case .group(let g):
            list = packages.filter { $0.source.group == g && $0.source.id != AdminScan.source.id }
            if applySearch, let f = sourceFilter { list = list.filter { $0.source.id == f } }
        }
        if !showDependencies && item != .deepScan { list = list.filter { !$0.isDependency } }
        let q = search.trimmed
        if applySearch && !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q) || ($0.summary?.localizedCaseInsensitiveContains(q) ?? false)
                    || ($0.path?.localizedCaseInsensitiveContains(q) ?? false) || $0.source.name.localizedCaseInsensitiveContains(q)
                    || ($0.context?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return list
    }

    var visibleRows: [PackageRow] {
        filtered(sidebar).map { PackageRow(package: $0, size: size(of: $0), lastUsed: lastUsed($0)) }
    }

    var selectedPackages: [Package] { packages.filter { selection.contains($0.id) } }

    var outdatedCount: Int { packages.filter(\.isOutdated).count }

    var inventoryCount: Int { packages.filter(isInventory).count }

    var inventorySize: Int64 { packages.filter(isInventory).reduce(0) { $0 + (size(of: $1) ?? 0) } }

    var groups: [SourceGroup] {
        SourceGroup.allCases.filter { g in packages.contains { $0.source.group == g && $0.source.id != AdminScan.source.id } }
    }

    func sources(in group: SourceGroup) -> [SourceInfo] {
        sources.filter { $0.group == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func request(_ action: PackageAction, _ pkgs: [Package]) {
        let applicable = pkgs.filter { $0.commands[action] != nil }
        guard !applicable.isEmpty else { return }
        pendingConfirmation = (action, applicable)
    }

    func confirm() {
        guard let (action, pkgs) = pendingConfirmation else { return }
        pendingConfirmation = nil
        let verb = action.title(for: pkgs.first?.source)
        let title = pkgs.count == 1 ? "\(verb): \(pkgs[0].name)" : tr("\(verb) \(pkgs.count) items", "\(verb) \(pkgs.count) elementos")
        let run = OperationRun(title: title, steps: pkgs.map { OperationStep(package: $0, action: action, command: $0.commands[action]!) })
        operation = run
        Task { await execute(run, asAdmin: false) }
    }

    func retryAsAdmin() {
        guard let run = operation else { return }
        Task { await execute(run, asAdmin: true) }
    }

    private func execute(_ run: OperationRun, asAdmin: Bool, rescanAfter: Bool = true) async {
        guard let env else { return }
        run.running = true
        run.finished = false
        var touched = Set<String>()
        for i in run.steps.indices {
            let st = run.steps[i].status
            if asAdmin ? st != .needsAdmin : st != .pending { continue }
            run.steps[i].status = .running
            let step = run.steps[i]
            touched.insert(step.package.source.id)
            run.log += "\n$ \(step.command.script)\n"
            if asAdmin || step.command.needsAdmin {
                run.log += tr("(with administrator permission)\n", "(con permisos de administrador)\n")
                let r = await Shell.admin(step.command.script, env: env)
                run.log += r.combined + (r.combined.hasSuffix("\n") || r.combined.isEmpty ? "" : "\n")
                if r.ok {
                    run.steps[i].status = .ok
                } else if Shell.isCancel(r) {
                    run.steps[i].status = .cancelled
                    run.log += tr("Cancelled.\n", "Cancelado.\n")
                } else {
                    run.steps[i].status = .failed
                }
            } else {
                let status = await Shell.stream(step.command.script, env: env) { chunk in
                    Task { @MainActor in run.log += chunk }
                }
                try? await Task.sleep(for: .milliseconds(50))
                if status == 0 {
                    run.steps[i].status = .ok
                } else {
                    let recent = String(run.log.suffix(4000))
                    run.steps[i].status = Shell.looksLikePermissionError(recent) ? .needsAdmin : .failed
                    run.log += tr("→ Exited with code \(status)\n", "→ Terminó con código \(status)\n")
                }
            }
        }
        run.running = false
        run.finished = true
        run.log += run.failedCount == 0 ? tr("\n✓ Done.\n", "\n✓ Listo.\n") : tr("\n✗ \(run.failedCount) step(s) did not finish.\n", "\n✗ \(run.failedCount) paso(s) no se completaron.\n")
        let doneAdmin = Set(run.steps.filter { $0.status == .ok && $0.package.source.id == AdminScan.source.id }.map(\.package.id))
        if !doneAdmin.isEmpty, let cur = results[adminIndex] {
            results[adminIndex] = cur.filter { !doneAdmin.contains($0.id) }
            rebuild()
        }
        if rescanAfter { await rescan(sources: touched) }
    }

    func rebuildCleanItems() {
        var items: [CleanItem] = catalog.map { e in
            CleanItem(id: e.id, title: e.label, explanation: e.explanation, paths: e.paths,
                      command: ShellCommand(e.script, admin: e.paths.contains { !FS.isWritable($0.deletingLastPathComponent) }),
                      safety: e.safety, size: nil)
        }
        func junk(_ id: String, _ title: String, _ why: String, _ paths: [String], _ script: String, admin: Bool = false, safety: CleanSafety = .safe, size: Int64? = nil) {
            items.append(CleanItem(id: id, title: title, explanation: why, paths: paths, command: ShellCommand(script, admin: admin), safety: safety, size: size))
        }
        let broken = packages.filter { $0.source.id == Src.loose.id && $0.id.contains("|broken:") }
        if !broken.isEmpty {
            junk("broken-links", tr("Broken command links", "Enlaces de comandos rotos"),
                 tr("Shortcuts to programs that no longer exist.", "Accesos a programas que ya no existen."),
                 broken.compactMap(\.path), broken.compactMap(\.path).map { "rm -f \(q($0))" }.joined(separator: "; "),
                 admin: broken.contains { $0.commands[.remove]?.needsAdmin == true }, size: 0)
        }
        let orphans = packages.filter { $0.source.id == Src.editorExt.id && $0.id.contains("|orphan:") }
        if !orphans.isEmpty {
            junk("editor-orphans", tr("Old editor extensions", "Extensiones viejas de editores"),
                 tr("Previous versions your editor no longer uses.", "Versiones anteriores que tu editor ya no usa."),
                 orphans.compactMap(\.path), orphans.compactMap(\.path).map { "rm -rf \(q($0))" }.joined(separator: "; "))
        }
        let reports = NSHomeDirectory().appendingPath("Library/Logs/DiagnosticReports")
        let devProcs = ["node", "python", "java", "ruby", "Xcode", "Simulator", "qemu", "docker", "com.docker", "swift", "clang", "cargo",
                        "rustc", "deno", "bun", "Code Helper", "Electron", "lldb", "xcodebuild", "Cursor", "gradle", "kotlin"]
        let crashes = FS.children(reports)
            .filter { f in (f.hasSuffix(".ips") || f.hasSuffix(".crash") || f.hasSuffix(".diag")) && devProcs.contains { f.hasPrefix($0) } }
            .map { reports.appendingPath($0) }
        if !crashes.isEmpty {
            junk("crash-reports", tr("Crash reports from dev tools", "Informes de fallos de herramientas"),
                 tr("Reports from Node, Python, Xcode, Docker and similar crashes. Only useful for debugging.",
                    "Reportes de cierres inesperados de Node, Python, Xcode, Docker… Solo sirven para depurar."),
                 crashes, crashes.map { "rm -f \(q($0))" }.joined(separator: "; "))
        }
        let oldClaude = packages.filter { $0.source.id == Src.versions.id && $0.name == "Claude Code" && $0.warning == nil }
        if !oldClaude.isEmpty {
            junk("old-claude", tr("Previous Claude Code versions", "Versiones anteriores de Claude Code"),
                 tr("Kept in case you want to roll back.", "Se guardan por si quieres volver atrás."),
                 oldClaude.compactMap(\.path), oldClaude.compactMap(\.path).map { "rm -rf \(q($0))" }.joined(separator: "; "), safety: .optional)
        }
        if FS.exists("/Applications/Xcode.app") {
            junk("simctl-unavailable", tr("Unavailable simulators", "Simuladores no disponibles"),
                 tr("Simulators for iOS versions you no longer have.", "Simuladores de versiones de iOS que ya no tienes."),
                 [], "/usr/bin/xcrun simctl delete unavailable")
        }
        let rootCaches = packages.filter { $0.source.id == AdminScan.source.id && $0.id.contains("|rootcache:") }
        if !rootCaches.isEmpty {
            junk("root-caches", tr("Caches left by sudo", "Cachés que dejó sudo"),
                 tr("Downloads saved while installing with sudo. Asks for Touch ID or your password.",
                    "Descargas guardadas al instalar con sudo. Pide Touch ID o tu contraseña."),
                 rootCaches.compactMap(\.path), rootCaches.compactMap(\.path).map { "rm -rf \(q($0))" }.joined(separator: "; "),
                 admin: true, size: rootCaches.reduce(0) { $0 + ($1.knownSize ?? 0) })
        }
        let previous = Dictionary(cleanItems.map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
        cleanItems = items.map { item in
            var item = item
            if item.size == nil, let s = previous[item.id] { item.size = s }
            return item
        }
        .sorted { $0.safety != $1.safety ? $0.safety < $1.safety : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        refreshCleanSizes()
        let missing = items.flatMap(\.paths).filter { usage[$0] == nil }
        if !missing.isEmpty { measure(missing) }
    }

    private func refreshCleanSizes() {
        guard !cleanItems.isEmpty else { return }
        for i in cleanItems.indices where !cleanItems[i].paths.isEmpty && cleanItems[i].id != "root-caches" && cleanItems[i].id != "broken-links" {
            let known = cleanItems[i].paths.compactMap { usage[$0]?.size }
            if known.count == cleanItems[i].paths.count { cleanItems[i].size = known.reduce(0, +) }
        }
    }

    var visibleCleanItems: [CleanItem] {
        cleanItems.filter { $0.size == nil || $0.size! > 0 || $0.paths.isEmpty || $0.id == "broken-links" }
    }

    func isCleanSelected(_ item: CleanItem) -> Bool { cleanChoices[item.id] ?? (item.safety == .safe) }

    func setCleanSelected(_ item: CleanItem, _ on: Bool) { cleanChoices[item.id] = on }

    func setCleanSelected(_ safety: CleanSafety, _ on: Bool) {
        for item in visibleCleanItems where item.safety == safety { cleanChoices[item.id] = on }
    }

    var cleanSelectedSize: Int64 {
        visibleCleanItems.filter(isCleanSelected).reduce(0) { $0 + ($1.size ?? 0) }
    }

    var safeCleanTotal: Int64 {
        visibleCleanItems.filter { $0.safety == .safe }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    func runCleanup() {
        let items = visibleCleanItems.filter(isCleanSelected)
        guard !items.isEmpty else { return }
        let freed = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let src = SourceInfo(id: "safeclean", en: "Safe Cleanup", es: "Limpieza segura", symbol: "trash", group: .caches,
                             removeEn: "Clean", removeEs: "Limpiar")
        let steps = items.map { item -> OperationStep in
            var p = Package(source: src, name: item.title, version: "", key: item.id)
            p.commands[.remove] = item.command
            return OperationStep(package: p, action: .remove, command: item.command)
        }
        let run = OperationRun(title: tr("Safe Cleanup", "Limpieza segura"), steps: steps)
        operation = run
        Task {
            await execute(run, asAdmin: false, rescanAfter: false)
            let ok = Set(run.steps.filter { $0.status == .ok }.map(\.package.id))
            let realFreed = items.filter { ok.contains("safeclean||\($0.id)") }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let message = run.failedCount == 0
                ? tr("You freed \(Sizes.format(freed)). Nothing was uninstalled.", "Liberaste \(Sizes.format(freed)). No se desinstaló nada.")
                : tr("You freed \(Sizes.format(realFreed)). \(run.failedCount) item(s) could not be cleaned.",
                     "Liberaste \(Sizes.format(realFreed)). \(run.failedCount) elemento(s) no se pudieron limpiar.")
            run.resultMessage = message
            lastCleanup = message
            for p in items.flatMap(\.paths) { usage[p] = nil }
            cleanChoices = [:]
            await scanAll()
        }
    }

    var hasFullDiskAccess: Bool {
        guard let h = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") else { return false }
        try? h.close()
        return true
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func runDeepScan() {
        guard let env, deepScanState != .scanning else { return }
        deepScanState = .scanning
        Task {
            async let adminResult = AdminScan.run(env, deep: true)
            async let projects = ProjectScanner(deep: true).scan(env)
            let (r, deepProjects) = await (adminResult, projects)
            if r.cancelled {
                deepScanState = .locked
                return
            }
            if let e = r.error {
                deepScanState = .failed(e)
                return
            }
            results[adminIndex] = r.packages
            if let i = Registry.all.firstIndex(where: { $0 is ProjectScanner }) {
                results[i] = deepProjects
                measure(deepProjects.compactMap(\.path))
            }
            rebuild()
            rebuildCleanItems()
            deepScanState = .done(Date())
        }
    }

    func reveal(_ p: Package) {
        guard let path = p.path else { return }
        reveal(path: path)
    }

    func reveal(path: String) {
        let target = FS.exists(path) ? path : path.deletingLastPathComponent
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func maintenanceCommands() -> [(String, ShellCommand)] {
        guard let env else { return [] }
        var c: [(String, ShellCommand)] = []
        if let b = env.which("brew") {
            c.append((tr("Homebrew: remove unused dependencies", "Homebrew: quitar dependencias que nadie usa"), ShellCommand("\(q(b)) autoremove")))
            c.append((tr("Homebrew: delete old versions", "Homebrew: borrar versiones antiguas"), ShellCommand("\(q(b)) cleanup -s --prune=all")))
            c.append((tr("Homebrew: check for updates", "Homebrew: buscar actualizaciones"), ShellCommand("\(q(b)) update")))
        }
        if let g = env.which("gem") { c.append((tr("RubyGems: delete old versions", "RubyGems: borrar versiones antiguas"), ShellCommand("\(q(g)) cleanup"))) }
        if let d = env.which("docker") {
            c.append((tr("Docker: delete unused images", "Docker: borrar imágenes sin usar"), ShellCommand("\(q(d)) image prune -f")))
            c.append((tr("Docker: delete build cache", "Docker: borrar caché de compilación"), ShellCommand("\(q(d)) builder prune -f")))
        }
        return c
    }

    func runMaintenance(_ label: String, _ cmd: ShellCommand) {
        var fake = Package(source: SourceInfo(id: "maint", en: "Maintenance", es: "Mantenimiento", symbol: "wrench", group: .tools), name: label, version: "")
        fake.commands[.repair] = cmd
        let run = OperationRun(title: label, steps: [OperationStep(package: fake, action: .repair, command: cmd)])
        operation = run
        Task {
            await execute(run, asAdmin: false, rescanAfter: false)
            await scanAll()
        }
    }
}

struct PackageRow: Identifiable, Hashable {
    let package: Package
    let size: Int64?
    let lastUsed: Date?

    var id: String { package.id }
    var name: String { package.name }
    var version: String { package.version }
    var latestKey: String { package.isOutdated ? (package.latest ?? "") : "" }
    var sourceKey: String { package.source.name + " " + (package.context ?? "") }
    var sizeKey: Int64 { size ?? -1 }
    var lastUsedKey: Date { lastUsed ?? .distantPast }
    var pathKey: String { package.path ?? "" }
}
