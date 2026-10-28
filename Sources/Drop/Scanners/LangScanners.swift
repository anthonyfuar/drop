import Foundation

private func cols(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

struct GemScanner: Scanner {
    static let snippet = #"""
    require "json"
    deps = Gem::Specification.flat_map { |s| s.runtime_dependencies.map(&:name) }.uniq
    gems = Gem::Specification.map { |s| { n: s.name, v: s.version.to_s, d: s.full_gem_path, s: s.summary, h: s.homepage, df: (s.respond_to?(:default_gem?) && s.default_gem?) } }
    puts({ gems: gems, deps: deps, ruby: RUBY_VERSION }.to_json)
    """#

    func scan(_ env: ShellEnv) async -> [Package] {
        guard let gem = env.which("gem") else { return [] }
        let sibling = gem.deletingLastPathComponent.appendingPath("ruby")
        let ruby = FileManager.default.isExecutableFile(atPath: sibling) ? sibling : (env.which("ruby") ?? "/usr/bin/ruby")
        let r = await Shell.run([ruby, "-e", Self.snippet], env: env.vars, timeout: 45)
        guard let d = parseJSON(r.out) as? [String: Any], let gems = d["gems"] as? [[String: Any]] else { return [] }
        let deps = Set(d["deps"] as? [String] ?? [])
        let ctx = "Ruby \(d["ruby"] as? String ?? "")"
        return gems.compactMap { g in
            guard let name = g["n"] as? String, let ver = g["v"] as? String, let dir = g["d"] as? String else { return nil }
            if g["df"] as? Bool == true || dir.hasPrefix("/System/") { return nil }
            var p = Package(source: Src.gem, name: name, version: ver, context: ctx, key: "\(name)-\(ver)")
            p.summary = g["s"] as? String
            p.homepage = g["h"] as? String
            p.path = dir
            p.isDependency = deps.contains(name)
            let admin = !FS.isWritable(dir.deletingLastPathComponent)
            p.commands = [
                .remove: ShellCommand("\(q(gem)) uninstall \(q(name)) -v \(q(ver)) -x -I", admin: admin),
                .update: ShellCommand("\(q(gem)) update \(q(name))", admin: admin),
                .repair: ShellCommand("\(q(gem)) pristine \(q(name)) --version \(q(ver))", admin: admin),
            ]
            return p
        }
    }

    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] {
        guard let r = await Shell.tool(env, "gem", ["outdated"], timeout: 90) else { return [:] }
        var m: [String: String] = [:]
        for l in r.out.lines {
            guard let open = l.firstIndex(of: "("), let lt = l.range(of: " < ") else { continue }
            let name = l[..<open].trimmed
            let latest = l[lt.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            for p in packages where p.name == name { m[p.id] = latest }
        }
        return m
    }
}

struct CargoScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let home = env.vars["CARGO_HOME"] ?? env.h(".cargo")
        guard let root = FS.json(home.appendingPath(".crates2.json")) as? [String: Any],
              let installs = root["installs"] as? [String: Any] else { return [] }
        let cargo = env.which("cargo").map(q) ?? q(home.appendingPath("bin/cargo"))
        return installs.keys.sorted().compactMap { key in
            let t = key.split(separator: " ").map(String.init)
            guard t.count >= 2 else { return nil }
            let info = installs[key] as? [String: Any] ?? [:]
            let bins = info["bins"] as? [String] ?? []
            var p = Package(source: Src.cargo, name: t[0], version: t[1])
            p.path = bins.first.map { home.appendingPath("bin/\($0)") }
            p.summary = bins.isEmpty ? nil : tr("Commands: ", "Comandos: ") + bins.joined(separator: ", ")
            if t.count >= 3 { p.details.append((tr("Source", "Origen"), t[2...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "()")))) }
            p.commands = [
                .remove: ShellCommand("\(cargo) uninstall \(q(t[0]))"),
                .update: ShellCommand("\(cargo) install \(q(t[0]))"),
                .repair: ShellCommand("\(cargo) install --force \(q(t[0])) --version \(q(t[1]))"),
            ]
            return p
        }
    }
}

struct GoBinScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let go = env.which("go")
        var binDir = env.h("go/bin")
        if let go {
            let r = await Shell.run([go, "env", "GOBIN", "GOPATH"], env: env.vars, timeout: 20)
            let l = r.out.lines
            if let gobin = l.first?.trimmed, !gobin.isEmpty { binDir = gobin }
            else if l.count > 1, let gp = l[1].split(separator: ":").first { binDir = String(gp).appendingPath("bin") }
        }
        let files = FS.children(binDir)
        guard !files.isEmpty else { return [] }
        return await withTaskGroup(of: Package.self) { group in
            for f in files {
                group.addTask {
                    let path = binDir.appendingPath(f)
                    var p = Package(source: Src.goBin, name: f, version: "—")
                    p.path = path
                    var module: String?
                    if let go {
                        let r = await Shell.run([go, "version", "-m", path], env: env.vars, timeout: 15)
                        for l in r.out.lines {
                            let c = cols(l)
                            if c.first == "path", c.count > 1 { module = c[1] }
                            if c.first == "mod", c.count > 2 { p.version = c[2]; p.summary = c[1] }
                        }
                    }
                    p.commands = [.remove: ShellCommand("rm -f \(q(path))")]
                    if let module, let go {
                        p.details.append((tr("Module", "Módulo"), module))
                        p.commands[.update] = ShellCommand("\(q(go)) install \(q(module + "@latest"))")
                        p.commands[.repair] = ShellCommand("\(q(go)) install \(q(module + "@" + p.version))")
                    }
                    return p
                }
            }
            var out: [Package] = []
            for await p in group { out.append(p) }
            return out
        }
    }
}

struct ComposerScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let composer = env.which("composer") else { return [] }
        async let showR = Shell.run([composer, "global", "show", "--format=json", "--no-interaction"], env: env.vars, timeout: 60)
        async let homeR = Shell.run([composer, "global", "config", "home", "--no-interaction"], env: env.vars, timeout: 30)
        async let directR = Shell.run([composer, "global", "show", "--direct", "--name-only", "--no-interaction"], env: env.vars, timeout: 60)
        let (show, home, direct) = await (showR, homeR, directR)
        guard let d = parseJSON(show.out) as? [String: Any], let items = d["installed"] as? [[String: Any]] else { return [] }
        let homeDir = home.out.trimmed.lines.last ?? env.h(".composer")
        let directSet = Set(direct.out.lines.map(\.trimmed))
        return items.compactMap { e in
            guard let name = e["name"] as? String else { return nil }
            var p = Package(source: Src.composer, name: name, version: e["version"] as? String ?? "?")
            p.summary = e["description"] as? String
            p.path = homeDir.appendingPath("vendor/\(name)")
            p.isDependency = !directSet.isEmpty && !directSet.contains(name)
            p.commands = [
                .remove: ShellCommand("\(q(composer)) global remove \(q(name)) --no-interaction"),
                .update: ShellCommand("\(q(composer)) global update \(q(name)) --with-all-dependencies --no-interaction"),
                .repair: ShellCommand("\(q(composer)) global reinstall \(q(name)) --no-interaction"),
            ]
            return p
        }
    }

    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] {
        guard let r = await Shell.tool(env, "composer", ["global", "outdated", "--format=json", "--no-interaction"], timeout: 90),
              let d = parseJSON(r.out) as? [String: Any], let items = d["installed"] as? [[String: Any]] else { return [:] }
        var m: [String: String] = [:]
        for e in items {
            if let n = e["name"] as? String, let l = e["latest"] as? String, let p = packages.first(where: { $0.name == n }) { m[p.id] = l }
        }
        return m
    }
}

struct PeclScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let pecl = env.which("pecl") else { return [] }
        let r = await Shell.run([pecl, "list"], env: env.vars, timeout: 30)
        var started = false
        var out: [Package] = []
        for l in r.out.lines {
            let c = cols(l)
            if c.first == "Package", c.dropFirst().first == "Version" { started = true; continue }
            guard started, c.count >= 2 else { continue }
            var p = Package(source: Src.pecl, name: c[0], version: c[1])
            if c.count > 2 { p.details.append((tr("Status", "Estado"), c[2])) }
            p.commands = [
                .remove: ShellCommand("\(q(pecl)) uninstall \(q(c[0]))"),
                .update: ShellCommand("\(q(pecl)) upgrade \(q(c[0]))"),
            ]
            out.append(p)
        }
        return out
    }
}

struct DotnetToolScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let dotnet = env.which("dotnet") else { return [] }
        let r = await Shell.run([dotnet, "tool", "list", "-g"], env: env.vars, timeout: 45)
        var out: [Package] = []
        for l in r.out.lines.dropFirst(2) {
            let c = cols(l)
            guard c.count >= 2 else { continue }
            var p = Package(source: Src.dotnetTool, name: c[0], version: c[1])
            p.path = env.h(".dotnet/tools/.store/\(c[0].lowercased())")
            if c.count > 2 { p.summary = tr("Commands: ", "Comandos: ") + c[2...].joined(separator: " ") }
            p.commands = [
                .remove: ShellCommand("\(q(dotnet)) tool uninstall -g \(q(c[0]))"),
                .update: ShellCommand("\(q(dotnet)) tool update -g \(q(c[0]))"),
                .repair: ShellCommand("\(q(dotnet)) tool uninstall -g \(q(c[0])) && \(q(dotnet)) tool install -g \(q(c[0])) --version \(q(c[1]))"),
            ]
            out.append(p)
        }
        return out
    }
}

struct DartPubScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let dart = env.which("dart") else { return [] }
        let r = await Shell.run([dart, "pub", "global", "list"], env: env.vars, timeout: 45)
        let cache = env.vars["PUB_CACHE"] ?? env.h(".pub-cache")
        return r.out.lines.compactMap { l in
            let c = cols(l)
            guard c.count >= 2, c[1].first?.isNumber == true else { return nil }
            var p = Package(source: Src.dartPub, name: c[0], version: c[1])
            p.path = cache.appendingPath("global_packages/\(c[0])")
            if c.count > 3 { p.summary = c[2...].joined(separator: " ") }
            p.commands = [
                .remove: ShellCommand("\(q(dart)) pub global deactivate \(q(c[0]))"),
                .update: ShellCommand("\(q(dart)) pub global activate \(q(c[0]))"),
            ]
            return p
        }
    }
}

struct LuaRocksScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let lr = env.which("luarocks") else { return [] }
        let r = await Shell.run([lr, "list", "--porcelain"], env: env.vars, timeout: 45)
        return r.out.lines.compactMap { l in
            let c = l.split(separator: "\t").map(String.init)
            guard c.count >= 2 else { return nil }
            var p = Package(source: Src.luarocks, name: c[0], version: c[1], key: "\(c[0])@\(c.count > 3 ? c[3] : "")")
            let tree = c.count > 3 ? c[3] : nil
            if let tree { p.path = tree.appendingPath("lib/luarocks/rocks-5.4/\(c[0])"); p.details.append((tr("Tree", "Árbol"), tree)) }
            let treeArg = tree.map { " --tree \(q($0))" } ?? ""
            p.commands = [
                .remove: ShellCommand("\(q(lr)) remove \(q(c[0]))\(treeArg)", admin: tree.map { !FS.isWritable($0) } ?? false),
                .update: ShellCommand("\(q(lr)) install \(q(c[0]))\(treeArg)", admin: tree.map { !FS.isWritable($0) } ?? false),
            ]
            return p
        }
    }
}

struct OpamScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let opam = env.which("opam") else { return [] }
        async let allR = Shell.run([opam, "list", "-i", "--color=never"], env: env.vars, timeout: 60)
        async let rootsR = Shell.run([opam, "list", "--installed-roots", "-s", "--color=never"], env: env.vars, timeout: 60)
        let (all, roots) = await (allR, rootsR)
        let rootSet = Set(roots.out.lines.map(\.trimmed))
        return all.out.lines.compactMap { l in
            guard !l.hasPrefix("#") else { return nil }
            let c = cols(l)
            guard c.count >= 2 else { return nil }
            var p = Package(source: Src.opam, name: c[0], version: c[1])
            if c.count > 2 { p.summary = c[2...].joined(separator: " ") }
            p.isDependency = !rootSet.isEmpty && !rootSet.contains(c[0])
            p.commands = [
                .remove: ShellCommand("\(q(opam)) remove -y \(q(c[0]))"),
                .update: ShellCommand("\(q(opam)) upgrade -y \(q(c[0]))"),
                .repair: ShellCommand("\(q(opam)) reinstall -y \(q(c[0]))"),
            ]
            return p
        }
    }
}

struct CabalScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let dir = env.h(".cabal/bin")
        return FS.children(dir).map { f in
            var p = Package(source: Src.cabal, name: f, version: "—")
            p.path = dir.appendingPath(f)
            if FS.resolve(p.path!) != p.path! { p.summary = "→ " + FS.resolve(p.path!).abbreviatingHome }
            p.commands = [.remove: ShellCommand("rm -f \(q(p.path!))")]
            return p
        }
    }
}

struct RPackageScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let rs = env.which("Rscript") else { return [] }
        let code = #"x <- installed.packages(priority = "NA"); write.table(x[, c("Package", "Version", "LibPath"), drop = FALSE], sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE)"#
        let r = await Shell.run([rs, "-e", code], env: env.vars, timeout: 60)
        return r.out.lines.compactMap { l in
            let c = l.split(separator: "\t").map(String.init)
            guard c.count >= 3 else { return nil }
            var p = Package(source: Src.rPkg, name: c[0], version: c[1], key: "\(c[0])@\(c[2])")
            p.path = c[2].appendingPath(c[0])
            let admin = !FS.isWritable(c[2])
            p.commands = [
                .remove: ShellCommand("\(q(rs)) -e \(q("remove.packages(\"\(c[0])\", lib = \"\(c[2])\")"))", admin: admin),
                .update: ShellCommand("\(q(rs)) -e \(q("install.packages(\"\(c[0])\", lib = \"\(c[2])\", repos = \"https://cloud.r-project.org\")"))", admin: admin),
            ]
            return p
        }
    }
}

struct JuliaScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let envs = env.h(".julia/environments")
        guard FS.isDir(envs), let julia = env.which("julia") else { return [] }
        var out: [Package] = []
        for e in FS.children(envs) {
            let project = (try? String(contentsOfFile: envs.appendingPath("\(e)/Project.toml"), encoding: .utf8)) ?? ""
            let manifest = (try? String(contentsOfFile: envs.appendingPath("\(e)/Manifest.toml"), encoding: .utf8)) ?? ""
            var inDeps = false
            for l in project.lines {
                if l.hasPrefix("[") { inDeps = l.trimmed == "[deps]"; continue }
                guard inDeps, let eq = l.firstIndex(of: "=") else { continue }
                let name = l[..<eq].trimmed
                var ver = "—"
                if let r = manifest.range(of: "[[deps.\(name)]]") {
                    let tail = manifest[r.upperBound...].prefix(600)
                    if let vr = tail.range(of: #"version = "([^"]+)""#, options: .regularExpression) {
                        ver = tail[vr].replacingOccurrences(of: "version = ", with: "").replacingOccurrences(of: "\"", with: "")
                    }
                }
                var p = Package(source: Src.julia, name: name, version: ver, context: e)
                p.path = env.h(".julia/packages/\(name)")
                let act = "using Pkg; Pkg.activate(\"\(envs.appendingPath(e))\"); "
                p.commands = [
                    .remove: ShellCommand("\(q(julia)) -e \(q(act + "Pkg.rm(\"\(name)\")"))"),
                    .update: ShellCommand("\(q(julia)) -e \(q(act + "Pkg.update(\"\(name)\")"))"),
                ]
                out.append(p)
            }
        }
        return out
    }
}

struct MintScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        guard let mint = env.which("mint") else { return [] }
        let r = await Shell.run([mint, "list"], env: env.vars, timeout: 30)
        var out: [Package] = []
        var current: String?
        for l in r.out.lines {
            let t = l.trimmed
            if t.hasPrefix("- ") {
                guard let name = current else { continue }
                let ver = String(t.dropFirst(2)).replacingOccurrences(of: " *", with: "")
                var p = Package(source: Src.mint, name: name, version: ver, key: "\(name)@\(ver)")
                p.path = env.h(".mint/packages")
                p.commands = [.remove: ShellCommand("\(q(mint)) uninstall \(q(name))")]
                out.append(p)
            } else if !t.isEmpty, !t.lowercased().hasPrefix("installed") {
                current = t.components(separatedBy: " ").last
            }
        }
        return out
    }
}
