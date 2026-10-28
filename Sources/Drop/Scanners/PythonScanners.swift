import Foundation

struct PythonInterpreter: Sendable, Hashable {
    let path: String
    let label: String
}

enum PythonDiscovery {
    static func interpreters(_ env: ShellEnv) -> [PythonInterpreter] {
        var found: [PythonInterpreter] = []
        var seen = Set<String>()
        func add(_ path: String, _ label: String) {
            guard FileManager.default.isExecutableFile(atPath: path) else { return }
            let real = FS.resolve(path)
            guard !seen.contains(real) else { return }
            seen.insert(real)
            found.append(PythonInterpreter(path: path, label: label))
        }
        let fm = FileManager.default
        func versioned(_ dir: String, _ pattern: (String) -> Bool) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter(pattern).sorted()
        }
        let pyN: (String) -> Bool = { $0.range(of: #"^python3\.\d+$"#, options: .regularExpression) != nil }

        for prefix in ["/opt/homebrew", "/usr/local"] {
            for f in versioned(prefix + "/bin", pyN) where FS.resolve(prefix + "/bin/" + f).contains("/Cellar/") {
                add(prefix + "/bin/" + f, "Homebrew \(f.dropFirst(6))")
            }
        }
        for v in versioned("/Library/Frameworks/Python.framework/Versions", { $0.first?.isNumber == true }) {
            add("/Library/Frameworks/Python.framework/Versions/\(v)/bin/python3", "python.org \(v)")
        }
        for (root, label) in [(env.h(".pyenv/versions"), "pyenv"), (env.h(".asdf/installs/python"), "asdf"),
                              (env.h(".local/share/mise/installs/python"), "mise"), (env.h(".rye/py"), "rye")] {
            for v in versioned(root, { !$0.hasPrefix(".") }) {
                let base = root.appendingPath(v)
                let bin = FS.exists(base + "/bin/python3") ? base + "/bin/python3" : base + "/install/bin/python3"
                add(bin, "\(label) \(v)")
            }
        }
        let uvDir = env.h(".local/share/uv/python")
        for v in versioned(uvDir, { $0.hasPrefix("cpython") || $0.hasPrefix("pypy") }) {
            add(uvDir + "/\(v)/bin/python3", "uv \(v.split(separator: "-").prefix(2).joined(separator: " "))")
        }
        if let p = env.which("python3"), !p.hasPrefix("/usr/bin/") { add(p, tr("python3 on PATH", "python3 del PATH")) }
        if FS.exists("/Library/Developer/CommandLineTools/usr/bin/python3") || FS.exists("/Applications/Xcode.app") {
            add("/usr/bin/python3", tr("System (macOS)", "Sistema (macOS)"))
        }
        return found
    }
}

struct PipScanner: Scanner {
    static let snippet = #"""
import sys, os, json, re, site, sysconfig
try:
    from importlib import metadata
except ImportError:
    print(json.dumps({"error": "old"})); sys.exit(0)
import importlib.util
apple = "/CommandLineTools/" in sys.prefix or "/Xcode" in sys.prefix
paths = []
if apple:
    paths.append("/Library/Python/%d.%d/site-packages" % sys.version_info[:2])
else:
    paths += [p for p in [sysconfig.get_path("purelib"), sysconfig.get_path("platlib")] if p]
usersite = site.getusersitepackages() if site.ENABLE_USER_SITE else None
if usersite: paths.append(usersite)
paths = [p for p in dict.fromkeys(paths) if os.path.isdir(p)]
em = os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED"))
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
pkgs, required, seen = [], set(), set()
for d in (metadata.distributions(path=paths) if paths else []):
    name = d.metadata["Name"]
    if not name or norm(name) in seen: continue
    seen.add(norm(name))
    for r in (d.requires or []):
        if "extra ==" in r: continue
        m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", r)
        if m: required.add(norm(m.group(1)))
    path = None
    try:
        base = str(d.locate_file(""))
        top = (d.read_text("top_level.txt") or "").split()
        cands = [os.path.join(base, name.replace("-", "_")), os.path.join(base, name.replace("-", "_").lower())] + [os.path.join(base, t) for t in top if not t.startswith("_")]
        for f in (d.files or []):
            first = str(f).split("/")[0]
            if first.endswith((".dist-info", ".egg-info", ".pth")) or first.startswith("..") or first == "__pycache__": continue
            cands.append(os.path.join(base, first)); break
        path = next((c for c in cands if os.path.exists(c)), None) or str(getattr(d, "_path", "")) or None
    except Exception:
        pass
    base = ""
    try: base = str(d.locate_file(""))
    except Exception: pass
    pkgs.append({"user": bool(usersite) and base.startswith(usersite), "base": base, "name": name, "version": d.version, "summary": d.metadata.get("Summary") or "", "home": d.metadata.get("Home-page") or "", "path": path, "installer": (d.read_text("INSTALLER") or "").strip()})
for p in pkgs: p["dep"] = norm(p["name"]) in required
print(json.dumps({"apple": apple, "v": sys.version.split()[0], "em": em, "pip": importlib.util.find_spec("pip") is not None, "paths": paths, "pkgs": pkgs}))
"""#

    func scan(_ env: ShellEnv) async -> [Package] {
        let interps = PythonDiscovery.interpreters(env)
        let uv = env.which("uv")
        return await withTaskGroup(of: [Package].self) { group in
            for i in interps {
                group.addTask {
                    let r = await Shell.run([i.path, "-E", "-c", Self.snippet], env: env.vars, cwd: "/", timeout: 40)
                    guard let d = parseJSON(r.out) as? [String: Any], let pkgs = d["pkgs"] as? [[String: Any]] else { return [] }
                    let em = d["em"] as? Bool ?? false
                    let hasPip = d["pip"] as? Bool ?? false
                    let pyver = d["v"] as? String ?? ""
                    let ctx = (d["apple"] as? Bool == true) ? tr("System (macOS) (\(pyver))", "Sistema (macOS) (\(pyver))") : "\(i.label) (\(pyver))"
                    let py = q(i.path)
                    let brk = em ? " --break-system-packages" : ""
                    func pip(_ args: String) -> String {
                        if hasPip { return "\(py) -m pip \(args)" }
                        if let uv { return "\(q(uv)) pip \(args.replacingOccurrences(of: " -y", with: "")) --python \(py)" }
                        return "\(py) -m pip \(args)"
                    }
                    return pkgs.compactMap { e -> Package? in
                        guard let name = e["name"] as? String else { return nil }
                        let ver = e["version"] as? String ?? "?"
                        var p = Package(source: Src.pip, name: name, version: ver, context: ctx)
                        p.summary = (e["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        p.homepage = (e["home"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        p.path = e["path"] as? String
                        p.isDependency = e["dep"] as? Bool ?? false
                        p.details.append((tr("Interpreter", "Intérprete"), i.path))
                        let isUser = e["user"] as? Bool ?? false
                        let usr = isUser ? " --user" : ""
                        let admin = !isUser && !FS.isWritable((e["base"] as? String) ?? "/")
                        p.details.append((tr("Scope", "Ámbito"), isUser ? tr("Your user only (~/Library/Python)", "Usuario (~/Library/Python)") : tr("Whole interpreter", "Global del intérprete")))
                        if let inst = e["installer"] as? String, !inst.isEmpty { p.details.append((tr("Installed with", "Instalado con"), inst)) }
                        if em { p.details.append((tr("Environment", "Entorno"), tr("Externally managed (PEP 668)", "Gestionado externamente (PEP 668)"))) }
                        if ["pip", "setuptools", "wheel"].contains(name.lowercased()) {
                            p.warning = tr("\(name) is part of the core of this Python interpreter.", "\(name) forma parte de la base de este intérprete de Python.")
                        }
                        p.commands = [
                            .remove: ShellCommand(pip("uninstall -y\(brk) \(q(name))"), admin: admin),
                            .update: ShellCommand(pip("install -U\(usr)\(brk) \(q(name))"), admin: admin),
                            .repair: ShellCommand(pip("install --force-reinstall --no-deps\(usr)\(brk) \(q(name + "==" + ver))"), admin: admin),
                        ]
                        return p
                    }
                }
            }
            var all: [Package] = []
            for await chunk in group { all += chunk }
            return all
        }
    }

    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] {
        let interps = PythonDiscovery.interpreters(env)
        var m: [String: String] = [:]
        await withTaskGroup(of: [String: String].self) { group in
            for i in interps {
                let mine = packages.filter { $0.details.first?.1 == i.path }
                guard !mine.isEmpty else { continue }
                group.addTask {
                    let r = await Shell.run([i.path, "-m", "pip", "list", "--outdated", "--format=json"], env: env.vars, cwd: "/", timeout: 120)
                    guard let arr = parseJSON(r.out) as? [[String: Any]] else { return [:] }
                    var out: [String: String] = [:]
                    let byName = Dictionary(mine.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
                    for e in arr {
                        if let n = (e["name"] as? String)?.lowercased(), let id = byName[n], let l = e["latest_version"] as? String { out[id] = l }
                    }
                    return out
                }
            }
            for await chunk in group { m.merge(chunk) { a, _ in a } }
        }
        return m
    }
}

struct PipxScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let pipx = env.which("pipx") else { return [] }
        let r = await Shell.run([pipx, "list", "--json"], env: env.vars, timeout: 60)
        guard let root = parseJSON(r.out) as? [String: Any], let venvs = root["venvs"] as? [String: Any] else { return [] }
        let homeR = await Shell.run([pipx, "environment", "--value", "PIPX_LOCAL_VENVS"], env: env.vars, timeout: 20)
        let venvRoot = homeR.ok && !homeR.out.trimmed.isEmpty ? homeR.out.trimmed : env.h(".local/pipx/venvs")
        return venvs.keys.sorted().map { name in
            let meta = ((venvs[name] as? [String: Any])?["metadata"] as? [String: Any]) ?? [:]
            let main = meta["main_package"] as? [String: Any] ?? [:]
            var p = Package(source: Src.pipx, name: name, version: main["package_version"] as? String ?? "?")
            p.path = venvRoot.appendingPath(name)
            if let apps = main["apps"] as? [String], !apps.isEmpty { p.summary = tr("Commands: ", "Comandos: ") + apps.joined(separator: ", ") }
            if let py = meta["python_version"] as? String { p.details.append(("Python", py)) }
            p.commands = [
                .remove: ShellCommand("\(q(pipx)) uninstall \(q(name))"),
                .update: ShellCommand("\(q(pipx)) upgrade \(q(name))"),
                .repair: ShellCommand("\(q(pipx)) reinstall \(q(name))"),
            ]
            return p
        }
    }
}

struct UvToolScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let uv = env.which("uv") else { return [] }
        let r = await Shell.run([uv, "tool", "list", "--show-paths"], env: env.vars, timeout: 30)
        var out: [Package] = []
        var current: Package?
        var bins: [String] = []
        func flush() {
            if var c = current {
                if !bins.isEmpty { c.summary = tr("Commands: ", "Comandos: ") + bins.joined(separator: ", ") }
                out.append(c)
            }
            bins = []
        }
        for l in r.out.lines {
            if l.hasPrefix("- ") {
                bins.append(String(l.dropFirst(2)).components(separatedBy: " (").first ?? "")
                continue
            }
            flush()
            let t = l.split(separator: " ", maxSplits: 2).map(String.init)
            guard t.count >= 2 else { current = nil; continue }
            var p = Package(source: Src.uvTool, name: t[0], version: Version.normalize(t[1]))
            if t.count == 3 { p.path = t[2].trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
            let n = q(t[0])
            p.commands = [
                .remove: ShellCommand("\(q(uv)) tool uninstall \(n)"),
                .update: ShellCommand("\(q(uv)) tool upgrade \(n)"),
                .repair: ShellCommand("\(q(uv)) tool upgrade --reinstall \(n)"),
            ]
            current = p
        }
        flush()
        return out
    }

    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] {
        guard let r = await Shell.tool(env, "uv", ["tool", "list", "--outdated"], timeout: 90) else { return [:] }
        var m: [String: String] = [:]
        for l in r.out.lines where !l.hasPrefix("- ") {
            let name = l.split(separator: " ").first.map(String.init) ?? ""
            if let range = l.range(of: #"latest:\s*v?([^\]\s]+)"#, options: .regularExpression),
               let p = packages.first(where: { $0.name == name }) {
                m[p.id] = String(l[range]).replacingOccurrences(of: "latest:", with: "").trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            }
        }
        return m
    }
}

struct CondaScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let conda = ["conda", "mamba", "micromamba"].lazy.compactMap({ env.which($0) }).first else { return [] }
        let r = await Shell.run([conda, "env", "list", "--json"], env: env.vars, timeout: 60)
        guard let d = parseJSON(r.out) as? [String: Any], let envs = d["envs"] as? [String] else { return [] }
        let base = envs.min(by: { $0.count < $1.count })
        return envs.map { path in
            let isBase = path == base
            let name = isBase ? "base" : path.lastPathComponent
            let meta = path.appendingPath("conda-meta")
            let count = FS.children(meta).filter { $0.hasSuffix(".json") }.count
            let pyMeta = FS.children(meta).first { $0.hasPrefix("python-3") && $0.hasSuffix(".json") }
            let pyVer = pyMeta.map { String($0.dropFirst(7).split(separator: "-").first ?? "") } ?? "—"
            var p = Package(source: Src.conda, name: name, version: pyVer, key: path)
            p.path = path
            p.summary = tr("\(count) packages", "\(count) paquetes") + (pyMeta != nil ? " · Python \(pyVer)" : "")
            p.details.append((tr("Executable", "Ejecutable"), conda))
            if isBase {
                p.warning = tr("This is Conda's base environment. To remove it, uninstall Conda/Miniforge.", "Es el entorno base de Conda; elimínalo desinstalando Conda/Miniforge.")
                p.commands = [.update: ShellCommand("\(q(conda)) update -y --all -p \(q(path))")]
            } else {
                p.commands = [
                    .remove: ShellCommand("\(q(conda)) env remove -y -p \(q(path))"),
                    .update: ShellCommand("\(q(conda)) update -y --all -p \(q(path))"),
                ]
            }
            return p
        }
    }
}
