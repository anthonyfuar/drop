import Foundation

private func cols(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

struct EditorExtensionScanner: Scanner {
    static let editors: [(name: String, dir: String, cli: String, app: String)] = [
        ("VS Code", ".vscode/extensions", "code", "Visual Studio Code.app"),
        ("VS Code Insiders", ".vscode-insiders/extensions", "code-insiders", "Visual Studio Code - Insiders.app"),
        ("Cursor", ".cursor/extensions", "cursor", "Cursor.app"),
        ("Windsurf", ".windsurf/extensions", "windsurf", "Windsurf.app"),
        ("VSCodium", ".vscode-oss/extensions", "codium", "VSCodium.app"),
        ("Trae", ".trae/extensions", "trae", "Trae.app"),
        ("Kiro", ".kiro/extensions", "kiro", "Kiro.app"),
        ("Positron", ".positron/extensions", "positron", "Positron.app"),
        ("Antigravity", ".antigravity/extensions", "antigravity", "Antigravity.app"),
        ("Void", ".void-editor/extensions", "void", "Void.app"),
    ]

    func scan(_ env: ShellEnv) async -> [Package] {
        var out: [Package] = []
        for ed in Self.editors {
            let dir = env.h(ed.dir)
            guard FS.isDir(dir) else { continue }
            let cliInApp = "/Applications/\(ed.app)/Contents/Resources/app/bin/\(ed.cli)"
            let cli = env.which(ed.cli) ?? (FileManager.default.isExecutableFile(atPath: cliInApp) ? cliInApp : nil)
            var referenced = Set<String>()
            var entries: [(id: String, version: String, path: String)] = []
            if let arr = FS.json(dir.appendingPath("extensions.json")) as? [[String: Any]] {
                for e in arr {
                    guard let id = (e["identifier"] as? [String: Any])?["id"] as? String else { continue }
                    let loc = e["location"] as? [String: Any]
                    let path = (loc?["fsPath"] as? String) ?? (loc?["path"] as? String) ?? dir.appendingPath(e["relativeLocation"] as? String ?? "")
                    referenced.insert(path.lastPathComponent)
                    entries.append((id, e["version"] as? String ?? "?", path))
                }
            }
            let obsolete = (FS.json(dir.appendingPath(".obsolete")) as? [String: Any]).map { Set($0.keys) } ?? []
            for folder in FS.children(dir) where FS.isDir(dir.appendingPath(folder)) {
                if referenced.contains(folder) && !obsolete.contains(folder) { continue }
                let pj = FS.json(dir.appendingPath("\(folder)/package.json")) as? [String: Any]
                var p = Package(source: Src.editorExt, name: (pj?["displayName"] as? String).flatMap { $0.hasPrefix("%") ? nil : $0 } ?? folder,
                                version: pj?["version"] as? String ?? "?", context: ed.name, key: "orphan:\(folder)")
                p.path = dir.appendingPath(folder)
                p.summary = tr("Old version or leftover no longer used by \(ed.name)", "Versión antigua o resto no usado por \(ed.name)")
                p.isDependency = true
                p.commands = [.remove: ShellCommand("rm -rf \(q(p.path!))")]
                out.append(p)
            }
            for e in entries where !obsolete.contains(e.path.lastPathComponent) {
                let pj = FS.json(e.path.appendingPath("package.json")) as? [String: Any]
                var p = Package(source: Src.editorExt, name: e.id, version: e.version, context: ed.name)
                p.path = e.path
                let display = pj?["displayName"] as? String
                let desc = pj?["description"] as? String
                p.summary = [display, desc].compactMap { $0 }.filter { !$0.hasPrefix("%") }.joined(separator: " — ")
                if p.summary?.isEmpty == true { p.summary = nil }
                if let repo = (pj?["repository"] as? [String: Any])?["url"] as? String { p.homepage = repo.replacingOccurrences(of: "git+", with: "") }
                if let cli {
                    p.commands = [
                        .remove: ShellCommand("\(q(cli)) --uninstall-extension \(q(e.id))"),
                        .update: ShellCommand("\(q(cli)) --install-extension \(q(e.id)) --force"),
                        .repair: ShellCommand("\(q(cli)) --install-extension \(q(e.id + "@" + e.version)) --force"),
                    ]
                } else {
                    p.commands = [.remove: ShellCommand("rm -rf \(q(e.path))")]
                }
                out.append(p)
            }
        }
        return out
    }
}

struct GhExtensionScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let gh = env.which("gh") else { return [] }
        let r = await Shell.run([gh, "extension", "list"], env: env.vars, timeout: 30)
        let base = env.vars["XDG_DATA_HOME"].map { $0.appendingPath("gh/extensions") } ?? env.h(".local/share/gh/extensions")
        return r.out.lines.compactMap { l in
            let c = l.split(separator: "\t").map { String($0).trimmed }
            guard c.count >= 2 else { return nil }
            let name = c[0].hasPrefix("gh ") ? String(c[0].dropFirst(3)) : c[0]
            var p = Package(source: Src.ghExt, name: name, version: c.count > 2 ? c[2] : "—")
            p.summary = c[1]
            p.homepage = "https://github.com/\(c[1])"
            p.path = base.appendingPath("gh-\(name)")
            p.commands = [
                .remove: ShellCommand("\(q(gh)) extension remove \(q(name))"),
                .update: ShellCommand("\(q(gh)) extension upgrade \(q(name))"),
            ]
            return p
        }
    }
}

struct OllamaScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let modelsDir = env.vars["OLLAMA_MODELS"] ?? env.h(".ollama/models")
        let manifests = modelsDir.appendingPath("manifests")
        guard FS.isDir(manifests) else { return [] }
        let ollama = env.which("ollama")
        var out: [Package] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: manifests) else { return [] }
        for case let rel as String in en.allObjects {
            let full = manifests.appendingPath(rel)
            guard !FS.isDir(full), let m = FS.json(full) as? [String: Any] else { continue }
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count >= 3 else { continue }
            let tag = parts.last!
            let repo = parts[parts.count - 2]
            let ns = parts[parts.count - 3]
            let host = parts.count >= 4 ? parts[parts.count - 4] : ""
            let model = (host == "registry.ollama.ai" && ns == "library") ? repo : (host == "registry.ollama.ai" ? "\(ns)/\(repo)" : "\(host)/\(ns)/\(repo)")
            let layers = (m["layers"] as? [[String: Any]] ?? []) + [m["config"] as? [String: Any] ?? [:]]
            let size = layers.reduce(Int64(0)) { $0 + Int64(($1["size"] as? Int) ?? 0) }
            var p = Package(source: Src.ollama, name: "\(model):\(tag)", version: tag)
            p.knownSize = size
            p.path = full
            p.summary = tr("Local AI model", "Modelo de IA local")
            let ref = q("\(model):\(tag)")
            let bin = ollama.map(q) ?? "ollama"
            p.commands = [
                .remove: ShellCommand("\(bin) rm \(ref)"),
                .update: ShellCommand("\(bin) pull \(ref)"),
            ]
            out.append(p)
        }
        return out
    }
}

struct DockerScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        var out: [Package] = []
        for engine in ["docker", "podman"] {
            guard let bin = env.which(engine) else { continue }
            let r = await Shell.run([bin, "images", "--format", "{{json .}}"], env: env.vars, timeout: 12)
            guard r.ok else { continue }
            for l in r.out.lines {
                guard let d = parseJSON(l) as? [String: Any] else { continue }
                let repo = d["Repository"] as? String ?? "<none>"
                let tag = d["Tag"] as? String ?? "<none>"
                let id = d["ID"] as? String ?? d["Id"] as? String ?? ""
                var p = Package(source: Src.docker, name: repo, version: tag, context: engine == "docker" ? nil : "Podman", key: "\(engine):\(id):\(repo):\(tag)")
                p.knownSize = Self.parseSize(d["Size"] as? String ?? "")
                p.summary = [d["CreatedSince"] as? String, "ID \(id.prefix(12))"].compactMap { $0 }.joined(separator: " · ")
                p.isDependency = repo == "<none>"
                let ref = (repo == "<none>" || tag == "<none>") ? id : "\(repo):\(tag)"
                p.commands = [.remove: ShellCommand("\(q(bin)) rmi \(q(ref))")]
                if repo != "<none>" { p.commands[.update] = ShellCommand("\(q(bin)) pull \(q(ref))") }
                out.append(p)
            }
        }
        return out
    }

    static func parseSize(_ s: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where s.hasSuffix(u) {
            if let v = Double(s.dropLast(u.count).trimmed) { return Int64(v * m) }
        }
        return nil
    }
}

struct HelmPluginScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let helm = env.which("helm") else { return [] }
        let r = await Shell.run([helm, "plugin", "list"], env: env.vars, timeout: 20)
        return r.out.lines.dropFirst().compactMap { l in
            let c = cols(l)
            guard c.count >= 2 else { return nil }
            var p = Package(source: Src.helm, name: c[0], version: c[1])
            if c.count > 2 { p.summary = c[2...].joined(separator: " ") }
            p.commands = [
                .remove: ShellCommand("\(q(helm)) plugin uninstall \(q(c[0]))"),
                .update: ShellCommand("\(q(helm)) plugin update \(q(c[0]))"),
            ]
            return p
        }
    }
}

struct KrewScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let root = env.vars["KREW_ROOT"] ?? env.h(".krew")
        let receipts = root.appendingPath("receipts")
        guard FS.isDir(receipts), let kubectl = env.which("kubectl") else { return [] }
        return FS.children(receipts).filter { $0.hasSuffix(".yaml") }.map { f in
            let name = String(f.dropLast(5))
            let text = (try? String(contentsOfFile: receipts.appendingPath(f), encoding: .utf8)) ?? ""
            let ver = text.lines.first { $0.trimmed.hasPrefix("version:") }.map { $0.trimmed.dropFirst(8).trimmed } ?? "—"
            var p = Package(source: Src.krew, name: name, version: ver)
            p.path = root.appendingPath("store/\(name)")
            p.commands = [
                .remove: ShellCommand("\(q(kubectl)) krew uninstall \(q(name))"),
                .update: ShellCommand("\(q(kubectl)) krew upgrade \(q(name))"),
            ]
            return p
        }
    }
}
