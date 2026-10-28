import Foundation

struct HomebrewScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        var brews = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", env.h(".linuxbrew/bin/brew")].filter { FileManager.default.isExecutableFile(atPath: $0) }
        if brews.isEmpty, let b = env.which("brew") { brews = [b] }
        var all: [Package] = []
        for brew in brews {
            let ctx: String? = brews.count > 1 ? (brew.hasPrefix("/opt/") ? "Apple Silicon" : "Intel") : nil
            all += await scanOne(brew: brew, context: ctx, env: env)
        }
        return all
    }

    private func scanOne(brew: String, context: String?, env: ShellEnv) async -> [Package] {
        let prefix = brew.deletingLastPathComponent.deletingLastPathComponent
        async let infoR = Shell.run([brew, "info", "--json=v2", "--installed"], env: env.vars, timeout: 90)
        async let tapsR = Shell.run([brew, "tap"], env: env.vars, timeout: 30)
        let (info, taps) = await (infoR, tapsR)
        let b = q(brew)
        var out: [Package] = []

        if let root = parseJSON(info.out) as? [String: Any] {
            let formulae = root["formulae"] as? [[String: Any]] ?? []
            var dependents: [String: [String]] = [:]
            for f in formulae {
                let name = f["name"] as? String ?? ""
                for inst in f["installed"] as? [[String: Any]] ?? [] {
                    for dep in inst["runtime_dependencies"] as? [[String: Any]] ?? [] {
                        if let dn = (dep["full_name"] as? String)?.split(separator: "/").last.map(String.init) {
                            dependents[dn, default: []].append(name)
                        }
                    }
                }
            }
            for f in formulae {
                guard let name = f["name"] as? String else { continue }
                let installed = (f["installed"] as? [[String: Any]]) ?? []
                let inst = installed.last
                let version = inst?["version"] as? String ?? (f["linked_keg"] as? String ?? "?")
                var p = Package(source: Src.brew, name: name, version: version, context: context)
                p.summary = f["desc"] as? String
                p.homepage = f["homepage"] as? String
                p.path = prefix.appendingPath("Cellar/\(name)")
                p.isDependency = !(installed.contains { $0["installed_on_request"] as? Bool == true })
                if f["outdated"] as? Bool == true {
                    p.latest = (f["versions"] as? [String: Any])?["stable"] as? String
                }
                let users = Array(Set(dependents[name] ?? [])).sorted()
                if !users.isEmpty {
                    p.details.append((tr("Required by", "Requerido por"), users.joined(separator: ", ")))
                    p.warning = tr("Other formulas depend on this package: \(users.prefix(6).joined(separator: ", "))\(users.count > 6 ? "…" : ""). Homebrew won't remove it while they're still installed.", "Otras fórmulas dependen de este paquete: \(users.prefix(6).joined(separator: ", "))\(users.count > 6 ? "…" : ""). Homebrew se negará a quitarlo mientras sigan instaladas.")
                }
                if f["pinned"] as? Bool == true { p.details.append((tr("Pinned", "Fijado"), tr("Yes (brew pin)", "Sí (brew pin)"))) }
                if installed.count > 1 { p.details.append((tr("Versions on disk", "Versiones en disco"), installed.compactMap { $0["version"] as? String }.joined(separator: ", "))) }
                if let tap = f["tap"] as? String { p.details.append(("Tap", tap)) }
                p.details.append((tr("Installed on request", "Instalado a petición"), p.isDependency ? tr("No (dependency)", "No (dependencia)") : tr("Yes", "Sí")))
                p.commands = [
                    .remove: ShellCommand("\(b) uninstall --formula \(q(name))"),
                    .update: ShellCommand("\(b) upgrade --formula \(q(name))"),
                    .repair: ShellCommand("\(b) reinstall --formula \(q(name))"),
                ]
                out.append(p)
            }
            for c in root["casks"] as? [[String: Any]] ?? [] {
                guard let token = c["token"] as? String else { continue }
                let clean = { (v: String) in String(v.split(separator: ",").first ?? Substring(v)) }
                let version = clean(c["installed"] as? String ?? "?")
                var p = Package(source: Src.cask, name: token, version: version, context: context)
                p.summary = c["desc"] as? String ?? (c["name"] as? [String])?.first
                p.homepage = c["homepage"] as? String
                p.path = prefix.appendingPath("Caskroom/\(token)")
                if c["outdated"] as? Bool == true || (c["version"] as? String).map({ $0 != version && $0 != "latest" }) == true {
                    p.latest = (c["version"] as? String).map(clean)
                }
                if let names = c["name"] as? [String], let n = names.first { p.details.append((tr("Name", "Nombre"), n)) }
                let apps = (c["artifacts"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["app"] as? [Any] }.flatMap { $0 }.compactMap { $0 as? String }
                if !apps.isEmpty { p.details.append(("Apps", apps.joined(separator: ", "))) }
                p.commands = [
                    .remove: ShellCommand("\(b) uninstall --cask \(q(token))"),
                    .update: ShellCommand("\(b) upgrade --cask \(q(token))"),
                    .repair: ShellCommand("\(b) reinstall --cask \(q(token))"),
                ]
                out.append(p)
            }
        }

        for tap in taps.out.lines.map(\.trimmed).filter({ !$0.isEmpty && $0.contains("/") }) {
            let parts = tap.split(separator: "/")
            var p = Package(source: Src.tap, name: tap, version: "—", context: context)
            p.path = prefix.appendingPath("Library/Taps/\(parts[0])/homebrew-\(parts[1])")
            if tap == "homebrew/core" || tap == "homebrew/cask" { p.warning = tr("Official Homebrew tap.", "Tap oficial de Homebrew.") }
            p.commands = [
                .remove: ShellCommand("\(b) untap \(q(tap))"),
                .update: ShellCommand("\(b) update"),
            ]
            out.append(p)
        }
        return out
    }
}

struct MacPortsScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let port = env.which("port") else { return [] }
        async let allR = Shell.run([port, "-q", "installed"], env: env.vars, timeout: 60)
        async let reqR = Shell.run([port, "-q", "installed", "requested"], env: env.vars, timeout: 60)
        async let outdR = Shell.run([port, "-q", "outdated"], env: env.vars, timeout: 60)
        let (all, req, outd) = await (allR, reqR, outdR)
        let requested = Set(req.out.lines.compactMap { $0.trimmed.split(separator: " ").first.map(String.init) })
        var latest: [String: String] = [:]
        for l in outd.out.lines {
            let t = l.split(whereSeparator: \.isWhitespace).map(String.init)
            if t.count >= 4, t[2] == "<" { latest[t[0]] = t[3] }
        }
        let prefix = port.deletingLastPathComponent.deletingLastPathComponent
        var seen = Set<String>()
        var out: [Package] = []
        for l in all.out.lines {
            let t = l.trimmed.split(separator: " ").map(String.init)
            guard t.count >= 2, t[1].hasPrefix("@") else { continue }
            let name = t[0]
            let active = l.contains("(active)")
            let version = String(t[1].dropFirst())
            if !active && seen.contains(name) { continue }
            seen.insert(name)
            var p = Package(source: Src.macports, name: name, version: version, key: "\(name)@\(version)")
            p.isDependency = !requested.contains(name)
            p.latest = latest[name]
            p.path = prefix.appendingPath("var/macports/software/\(name)")
            if !active { p.details.append((tr("Status", "Estado"), tr("Inactive", "Inactivo"))) }
            p.commands = [
                .remove: ShellCommand("\(q(port)) -N uninstall \(q(name)) @\(version)", admin: true),
                .update: ShellCommand("\(q(port)) -N upgrade \(q(name))", admin: true),
                .repair: ShellCommand("\(q(port)) -N -n upgrade --force \(q(name))", admin: true),
            ]
            out.append(p)
        }
        return out
    }
}

struct NixScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard env.has("nix") || env.has("nix-env") else { return [] }
        var out: [Package] = []
        if let r = await Shell.tool(env, "nix", ["--extra-experimental-features", "nix-command flakes", "profile", "list", "--json"], timeout: 60), r.ok,
           let root = parseJSON(r.out) as? [String: Any] {
            var items: [(String, [String: Any])] = []
            if let dict = root["elements"] as? [String: Any] {
                items = dict.compactMap { k, v in (v as? [String: Any]).map { (k, $0) } }
            } else if let arr = root["elements"] as? [[String: Any]] {
                items = arr.enumerated().map { (String($0.offset), $0.element) }
            }
            for (key, el) in items {
                let store = (el["storePaths"] as? [String])?.first ?? ""
                let (pname, ver) = Self.splitStorePath(store)
                let name = Int(key) == nil ? key : pname
                var p = Package(source: Src.nix, name: name, version: ver, key: key)
                p.path = store.isEmpty ? nil : store
                p.summary = el["originalUrl"] as? String ?? el["attrPath"] as? String
                let ref = q(key)
                p.commands = [
                    .remove: ShellCommand("nix --extra-experimental-features 'nix-command flakes' profile remove \(ref)"),
                    .update: ShellCommand("nix --extra-experimental-features 'nix-command flakes' profile upgrade \(ref)"),
                ]
                out.append(p)
            }
        }
        if out.isEmpty, let r = await Shell.tool(env, "nix-env", ["-q", "--json"], timeout: 60),
           let dict = parseJSON(r.out) as? [String: Any] {
            for (attr, v) in dict {
                guard let d = v as? [String: Any] else { continue }
                let pname = d["pname"] as? String ?? attr
                var p = Package(source: Src.nix, name: pname, version: d["version"] as? String ?? "?")
                p.path = (d["outputs"] as? [String: Any])?["out"] as? String
                p.commands = [
                    .remove: ShellCommand("nix-env -e \(q(pname))"),
                    .update: ShellCommand("nix-env -u \(q(pname))"),
                ]
                out.append(p)
            }
        }
        return out
    }

    static func splitStorePath(_ s: String) -> (String, String) {
        let base = s.lastPathComponent
        guard let dash = base.firstIndex(of: "-") else { return (base, "?") }
        let rest = String(base[base.index(after: dash)...])
        let comps = rest.split(separator: "-")
        if let i = comps.firstIndex(where: { $0.first?.isNumber == true }) {
            return (comps[..<i].joined(separator: "-"), comps[i...].joined(separator: "-"))
        }
        return (rest, "?")
    }
}

struct PkgReceiptScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let list = await Shell.run(["/usr/sbin/pkgutil", "--pkgs"], env: env.vars, timeout: 30)
        let ids = list.out.lines.map(\.trimmed).filter { !$0.isEmpty && !$0.lowercased().hasPrefix("com.apple.") }
        return await withTaskGroup(of: Package?.self) { group in
            for id in ids {
                group.addTask { await Self.describe(id, env: env) }
            }
            var out: [Package] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }
    }

    static func describe(_ id: String, env: ShellEnv) async -> Package? {
        async let infoR = Shell.run(["/usr/sbin/pkgutil", "--pkg-info-plist", id], env: env.vars, timeout: 20)
        async let filesR = Shell.run(["/usr/sbin/pkgutil", "--files", id], env: env.vars, timeout: 30)
        let (info, files) = await (infoR, filesR)
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(info.out.utf8), format: nil) as? [String: Any] else { return nil }
        let version = plist["pkg-version"] as? String ?? "?"
        let volume = plist["volume"] as? String ?? "/"
        let location = plist["install-location"] as? String ?? "/"
        let root = (volume as NSString).appendingPathComponent(location)
        let fileList = files.out.lines
        var p = Package(source: Src.pkg, name: id, version: version)
        if id == "sh.brew.homebrew" {
            p.summary = tr("Homebrew installer", "Instalador de Homebrew")
        } else if location.hasSuffix(".app") {
            p.path = root
            p.summary = location.lastPathComponent
        } else if let app = fileList.first(where: { $0.hasSuffix(".app") && !$0.dropLast(4).contains(".app/") }) {
            p.path = root.appendingPath(app)
            p.summary = app.lastPathComponent
        } else if let bin = fileList.first(where: { $0.contains("/bin/") && !$0.hasSuffix("/") }) {
            p.path = root.appendingPath(bin)
            p.summary = tr("Includes \(bin.lastPathComponent)", "Incluye \(bin.lastPathComponent)")
        } else if location != "/" {
            p.path = root
        }
        if let t = plist["install-time"] as? Int {
            p.details.append((tr("Installed", "Instalado"), Date(timeIntervalSince1970: TimeInterval(t)).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.current.locale))))
        }
        p.details.append((tr("Registered files", "Archivos registrados"), "\(fileList.count)"))
        p.details.append((tr("Location", "Ubicación"), root))
        if id == "sh.brew.homebrew" {
            p.warning = tr("This receipt belongs to the Homebrew installer. Removing it would break Homebrew.", "Este recibo pertenece al instalador de Homebrew. Quitarlo rompería Homebrew.")
        } else {
            p.warning = tr("This deletes the \(fileList.count) files this installer added and forgets its receipt. You'll need your administrator password.", "Se borrarán los \(fileList.count) archivos que este instalador registró y se olvidará el recibo. Requiere contraseña de administrador.")
        }
        let r = q(root)
        let i = q(id)
        p.commands = [
            .remove: ShellCommand("""
            R=\(r); /usr/sbin/pkgutil --only-files --files \(i) | while IFS= read -r f; do rm -f "$R/$f"; done; \
            /usr/sbin/pkgutil --only-dirs --files \(i) | sort -r | while IFS= read -r d; do rmdir "$R/$d" 2>/dev/null; done; \
            /usr/sbin/pkgutil --forget \(i)
            """, admin: true),
        ]
        return p
    }
}
