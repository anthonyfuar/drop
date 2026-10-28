import Foundation

private func nodeModuleInfo(_ dir: String) -> (version: String?, desc: String?, homepage: String?) {
    let j = FS.json(dir.appendingPath("package.json")) as? [String: Any]
    return (j?["version"] as? String, j?["description"] as? String, j?["homepage"] as? String)
}

struct NpmScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let npm = env.which("npm") else { return [] }
        let rootR = await Shell.run([npm, "root", "-g"], env: env.vars, timeout: 30)
        let root = rootR.out.trimmed
        guard !root.isEmpty, FS.isDir(root) else { return [] }
        var out: [Package] = []
        var names: [String] = []
        for entry in FS.children(root) {
            if entry.hasPrefix("@") {
                let scoped = FS.children(root.appendingPath(entry))
                names += scoped.isEmpty ? [entry] : scoped.map { "\(entry)/\($0)" }
            } else {
                names.append(entry)
            }
        }
        let binDir = root.deletingLastPathComponent.deletingLastPathComponent.appendingPath("bin")
        let rootWritable = FS.isWritable(root) && (!FS.isDir(binDir) || FS.isWritable(binDir))
        for name in names {
            let dir = root.appendingPath(name)
            let info = nodeModuleInfo(dir)
            let writable = rootWritable && FS.isWritable(dir)
            var p = Package(source: Src.npm, name: name, version: info.version ?? "?")
            p.summary = info.desc
            p.homepage = info.homepage
            p.path = dir
            if name == "npm" || name == "corepack" {
                p.warning = name == "npm" ? tr("This is npm itself. If you remove it, you won't be able to install global packages until you reinstall Node.", "Es el propio npm. Si lo quitas no podrás instalar paquetes globales hasta reinstalar Node.") : tr("This comes bundled with Node.js.", "Viene incluido con Node.js.")
            }
            if info.version == nil { p.details.append((tr("Status", "Estado"), tr("Folder without a package.json (leftovers from an incomplete install)", "Carpeta sin package.json (restos de una instalación incompleta)"))) }
            p.details.append((tr("Prefix", "Prefijo"), root))
            let n = q(name)
            p.commands = [
                .remove: info.version == nil ? ShellCommand("rm -rf \(q(dir))", admin: !writable) : ShellCommand("\(q(npm)) uninstall -g \(n)", admin: !writable),
                .update: ShellCommand("\(q(npm)) install -g \(q(name + "@latest"))", admin: !writable),
                .repair: ShellCommand("\(q(npm)) install -g --force \(q(name + "@" + (info.version ?? "latest")))", admin: !writable),
            ]
            if info.version == nil { p.commands[.update] = nil; p.commands[.repair] = nil }
            out.append(p)
        }
        return out
    }

    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] {
        guard let r = await Shell.tool(env, "npm", ["outdated", "-g", "--json"], timeout: 60),
              let d = parseJSON(r.out) as? [String: Any] else { return [:] }
        var m: [String: String] = [:]
        for p in packages {
            if let e = d[p.name] as? [String: Any], let l = e["latest"] as? String { m[p.id] = l }
        }
        return m
    }
}

struct NpxCacheScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        var cacheRoot = env.h(".npm")
        if let c = env.vars["npm_config_cache"], !c.isEmpty { cacheRoot = c }
        let base = cacheRoot.appendingPath("_npx")
        var out: [Package] = []
        for hash in FS.children(base) {
            let dir = base.appendingPath(hash)
            let pj = FS.json(dir.appendingPath("package.json")) as? [String: Any]
            let deps = (pj?["dependencies"] as? [String: Any])?.keys.sorted() ?? []
            let name = deps.first ?? hash
            let info = nodeModuleInfo(dir.appendingPath("node_modules/\(name)"))
            var p = Package(source: Src.npx, name: deps.isEmpty ? tr("(empty) \(hash)", "(vacío) \(hash)") : deps.joined(separator: " + "), version: info.version ?? "?", key: hash)
            p.summary = info.desc
            p.path = dir
            p.details.append(("Hash", hash))
            if let date = (try? FileManager.default.attributesOfItem(atPath: dir))?[.modificationDate] as? Date {
                p.details.append((tr("Last used", "Último uso"), date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.current.locale))))
            }
            p.commands = [.remove: ShellCommand("rm -rf \(q(dir))")]
            out.append(p)
        }
        return out
    }
}

struct PnpmScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let pnpm = env.which("pnpm") else { return [] }
        let r = await Shell.run([pnpm, "ls", "-g", "--depth=0", "--json"], env: env.vars, timeout: 45)
        var roots: [[String: Any]] = []
        if let a = parseJSON(r.out) as? [[String: Any]] { roots = a } else if let o = parseJSON(r.out) as? [String: Any] { roots = [o] }
        var out: [Package] = []
        for root in roots {
            for key in ["dependencies", "devDependencies"] {
                for (name, v) in root[key] as? [String: Any] ?? [:] {
                    let d = v as? [String: Any] ?? [:]
                    var p = Package(source: Src.pnpm, name: name, version: d["version"] as? String ?? "?")
                    p.path = d["path"] as? String
                    if let path = p.path { p.summary = nodeModuleInfo(path).desc }
                    p.commands = [
                        .remove: ShellCommand("\(q(pnpm)) remove -g \(q(name))"),
                        .update: ShellCommand("\(q(pnpm)) add -g \(q(name + "@latest"))"),
                        .repair: ShellCommand("\(q(pnpm)) add -g --force \(q(name + "@" + p.version))"),
                    ]
                    out.append(p)
                }
            }
        }
        return out
    }

    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] {
        guard let r = await Shell.tool(env, "pnpm", ["outdated", "-g", "--format", "json"], timeout: 60),
              let d = parseJSON(r.out) as? [String: Any] else { return [:] }
        var m: [String: String] = [:]
        for p in packages { if let l = (d[p.name] as? [String: Any])?["latest"] as? String { m[p.id] = l } }
        return m
    }
}

struct YarnScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        var dirs = [env.h(".config/yarn/global"), env.h("Library/Application Support/Yarn/global"), env.h(".yarn/global")]
        if let yarn = env.which("yarn"), let r = Optional(await Shell.run([yarn, "global", "dir"], env: env.vars, timeout: 20)), r.ok {
            let d = r.out.trimmed.lines.last ?? ""
            if !d.isEmpty { dirs.insert(d, at: 0) }
        }
        guard let dir = dirs.first(where: { FS.exists($0.appendingPath("package.json")) }) else { return [] }
        let deps = (FS.json(dir.appendingPath("package.json")) as? [String: Any])?["dependencies"] as? [String: Any] ?? [:]
        let yarn = env.which("yarn").map(q) ?? "yarn"
        return deps.keys.sorted().map { name in
            let mdir = dir.appendingPath("node_modules/\(name)")
            let info = nodeModuleInfo(mdir)
            var p = Package(source: Src.yarn, name: name, version: info.version ?? "?")
            p.summary = info.desc
            p.path = mdir
            p.commands = [
                .remove: ShellCommand("\(yarn) global remove \(q(name))"),
                .update: ShellCommand("\(yarn) global add \(q(name + "@latest"))"),
                .repair: ShellCommand("\(yarn) global add --force \(q(name))"),
            ]
            return p
        }
    }
}

struct BunScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let dir = env.h(".bun/install/global")
        guard let pj = FS.json(dir.appendingPath("package.json")) as? [String: Any] else { return [] }
        let bun = env.which("bun").map(q) ?? q(env.h(".bun/bin/bun"))
        let deps = pj["dependencies"] as? [String: Any] ?? [:]
        return deps.keys.sorted().map { name in
            let mdir = dir.appendingPath("node_modules/\(name)")
            let info = nodeModuleInfo(mdir)
            var p = Package(source: Src.bun, name: name, version: info.version ?? (deps[name] as? String ?? "?"))
            p.summary = info.desc
            p.path = mdir
            p.commands = [
                .remove: ShellCommand("\(bun) remove -g \(q(name))"),
                .update: ShellCommand("\(bun) add -g \(q(name + "@latest"))"),
                .repair: ShellCommand("\(bun) add -g --force \(q(name))"),
            ]
            return p
        }
    }
}

struct DenoScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let dir = env.vars["DENO_INSTALL_ROOT"].map { $0.appendingPath("bin") } ?? env.h(".deno/bin")
        guard FS.isDir(dir) else { return [] }
        let deno = env.which("deno").map(q) ?? "deno"
        return FS.children(dir).filter { $0 != "deno" && !$0.hasSuffix(".cmd") }.map { name in
            var p = Package(source: Src.deno, name: name, version: "—")
            p.path = dir.appendingPath(name)
            if let s = try? String(contentsOfFile: dir.appendingPath(name), encoding: .utf8),
               let line = s.lines.first(where: { $0.contains("deno") && $0.contains("run") }) {
                p.summary = String(line.trimmed.prefix(200))
            }
            p.commands = [.remove: ShellCommand("\(deno) uninstall -g \(q(name)) || \(deno) uninstall \(q(name))")]
            return p
        }
    }
}

struct VoltaScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let volta = env.which("volta") else { return [] }
        let r = await Shell.run([volta, "list", "all", "--format", "plain"], env: env.vars, timeout: 30)
        var out: [Package] = []
        for l in r.out.lines {
            let t = l.trimmed.split(separator: " ").map(String.init)
            guard t.count >= 2 else { continue }
            let kind = t[0]
            let spec = t[1]
            guard let at = spec.lastIndex(of: "@"), at != spec.startIndex else { continue }
            let name = String(spec[..<at]), ver = String(spec[spec.index(after: at)...])
            let label = kind == "runtime" ? "Runtime" : kind == "package-manager" ? tr("Package manager", "Gestor de paquetes") : tr("Package", "Paquete")
            var p = Package(source: Src.volta, name: name, version: ver, key: "\(kind):\(spec)")
            p.summary = label + (l.contains("(default)") ? tr(" · default", " · predeterminado") : "")
            switch kind {
            case "runtime": p.path = env.h(".volta/tools/image/node/\(ver)")
            case "package-manager": p.path = env.h(".volta/tools/image/\(name)/\(ver)")
            default: p.path = env.h(".volta/tools/image/packages/\(name)")
            }
            if kind == "package" {
                p.commands = [
                    .remove: ShellCommand("\(q(volta)) uninstall \(q(name))"),
                    .update: ShellCommand("\(q(volta)) install \(q(name + "@latest"))"),
                ]
            } else {
                p.commands = [.remove: ShellCommand("rm -rf \(q(p.path!))")]
            }
            out.append(p)
        }
        return out
    }
}
