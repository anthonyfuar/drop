import Foundation

struct RuntimeVersionsScanner: Scanner {
    private func dirs(_ root: String) -> [String] {
        FS.children(root).filter { name in
            let p = root.appendingPath(name)
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil
            return !isLink && FS.isDir(p)
        }
    }

    private func item(_ tool: String, _ version: String, manager: String, path: String,
                      remove: String? = nil, update: String? = nil, repair: String? = nil, warning: String? = nil) -> Package {
        var p = Package(source: Src.versions, name: tool, version: version, context: manager, key: path)
        p.path = path
        p.summary = manager
        p.warning = warning
        let admin = !FS.isWritable(path.deletingLastPathComponent)
        p.commands[.remove] = ShellCommand(remove ?? "rm -rf \(q(path))", admin: remove == nil && admin)
        if let update { p.commands[.update] = ShellCommand(update) }
        if let repair { p.commands[.repair] = ShellCommand(repair) }
        return p
    }

    func scan(_ env: ShellEnv) async -> [Package] {
        var out: [Package] = []
        let h = env.h
        let tool = { (n: String) in env.which(n).map(q) }

        let nvm = env.vars["NVM_DIR"] ?? h(".nvm")
        let nvmDefault = (try? String(contentsOfFile: nvm.appendingPath("alias/default"), encoding: .utf8))?.trimmed
        for v in dirs(nvm.appendingPath("versions/node")) {
            out.append(item("Node.js", v, manager: "nvm", path: nvm.appendingPath("versions/node/\(v)"),
                            warning: nvmDefault.map { v.hasPrefix("v" + $0) || v == $0 } == true ? tr("This is the default nvm version.", "Es la versión predeterminada de nvm.") : nil))
        }
        for root in [h(".local/share/fnm/node-versions"), h("Library/Application Support/fnm/node-versions"), h(".fnm/node-versions")] {
            for v in dirs(root) {
                out.append(item("Node.js", v, manager: "fnm", path: root.appendingPath(v),
                                remove: tool("fnm").map { "\($0) uninstall \(q(v))" }))
            }
        }
        let nPrefix = env.vars["N_PREFIX"] ?? "/usr/local"
        for v in dirs(nPrefix.appendingPath("n/versions/node")) {
            out.append(item("Node.js", v, manager: "n", path: nPrefix.appendingPath("n/versions/node/\(v)")))
        }
        for v in dirs(h(".nodenv/versions")) { out.append(item("Node.js", v, manager: "nodenv", path: h(".nodenv/versions/\(v)"))) }

        let asdf = env.vars["ASDF_DATA_DIR"] ?? h(".asdf")
        for plugin in dirs(asdf.appendingPath("installs")) {
            for v in dirs(asdf.appendingPath("installs/\(plugin)")) {
                out.append(item(plugin, v, manager: "asdf", path: asdf.appendingPath("installs/\(plugin)/\(v)"),
                                remove: tool("asdf").map { "\($0) uninstall \(q(plugin)) \(q(v))" }))
            }
        }
        let mise = env.vars["MISE_DATA_DIR"] ?? h(".local/share/mise")
        for t in dirs(mise.appendingPath("installs")) {
            for v in dirs(mise.appendingPath("installs/\(t)")) {
                out.append(item(t, v, manager: "mise", path: mise.appendingPath("installs/\(t)/\(v)"),
                                remove: tool("mise").map { "\($0) uninstall \(q(t + "@" + v))" }))
            }
        }

        let pyenv = env.vars["PYENV_ROOT"] ?? h(".pyenv")
        for v in dirs(pyenv.appendingPath("versions")) {
            out.append(item("Python", v, manager: "pyenv", path: pyenv.appendingPath("versions/\(v)"),
                            remove: tool("pyenv").map { "\($0) uninstall -f \(q(v))" }))
        }
        let uvPy = env.vars["UV_PYTHON_INSTALL_DIR"] ?? h(".local/share/uv/python")
        let uv = tool("uv")
        for v in dirs(uvPy) where !v.hasPrefix(".") {
            let ver = v.split(separator: "-").dropFirst().first.map(String.init) ?? v
            let impl = v.split(separator: "-").first.map(String.init) ?? "cpython"
            out.append(item(impl == "cpython" ? "Python" : impl, ver, manager: "uv", path: uvPy.appendingPath(v),
                            remove: uv.map { "\($0) python uninstall \(q(v))" },
                            update: uv.map { "\($0) python upgrade \(q(ver.split(separator: ".").prefix(2).joined(separator: ".")))" },
                            repair: uv.map { "\($0) python install --reinstall \(q(v))" }))
        }
        for v in dirs(h(".rye/py")) { out.append(item("Python", v, manager: "rye", path: h(".rye/py/\(v)"))) }

        for v in dirs(h(".rbenv/versions")) {
            out.append(item("Ruby", v, manager: "rbenv", path: h(".rbenv/versions/\(v)"), remove: tool("rbenv").map { "\($0) uninstall -f \(q(v))" }))
        }
        for v in dirs(h(".rvm/rubies")) where v != "default" { out.append(item("Ruby", v, manager: "rvm", path: h(".rvm/rubies/\(v)"))) }
        for v in dirs(h(".rubies")) { out.append(item("Ruby", v, manager: "chruby", path: h(".rubies/\(v)"))) }
        for v in dirs(h(".frum/versions")) { out.append(item("Ruby", v, manager: "frum", path: h(".frum/versions/\(v)"))) }

        let rustup = env.vars["RUSTUP_HOME"] ?? h(".rustup")
        let settings = (try? String(contentsOfFile: rustup.appendingPath("settings.toml"), encoding: .utf8)) ?? ""
        let rustDefault = settings.lines.first { $0.hasPrefix("default_toolchain") }?.components(separatedBy: "\"").dropFirst().first
        let rup = tool("rustup")
        for t in dirs(rustup.appendingPath("toolchains")) {
            out.append(item("Rust", t, manager: "rustup", path: rustup.appendingPath("toolchains/\(t)"),
                            remove: rup.map { "\($0) toolchain uninstall \(q(t))" },
                            update: rup.map { "\($0) update \(q(t))" },
                            warning: t == rustDefault ? tr("This is the default rustup toolchain.", "Es el toolchain predeterminado de rustup.") : nil))
        }

        for v in dirs(h("sdk")) where v.hasPrefix("go") { out.append(item("Go", String(v.dropFirst(2)), manager: "golang.org/dl", path: h("sdk/\(v)"))) }
        for v in dirs(h(".goenv/versions")) { out.append(item("Go", v, manager: "goenv", path: h(".goenv/versions/\(v)"))) }

        for root in ["/Library/Java/JavaVirtualMachines", h("Library/Java/JavaVirtualMachines")] {
            for jdk in dirs(root) {
                let plist = NSDictionary(contentsOfFile: root.appendingPath("\(jdk)/Contents/Info.plist"))
                let ver = (plist?["CFBundleShortVersionString"] as? String) ?? jdk
                out.append(item("Java (JDK)", ver, manager: root.hasPrefix("/Library") ? tr("System", "Sistema") : tr("User", "Usuario"), path: root.appendingPath(jdk)))
            }
        }
        let sdkman = env.vars["SDKMAN_DIR"] ?? h(".sdkman")
        for cand in dirs(sdkman.appendingPath("candidates")) {
            for v in dirs(sdkman.appendingPath("candidates/\(cand)")) where v != "current" {
                out.append(item(cand, v, manager: "SDKMAN!", path: sdkman.appendingPath("candidates/\(cand)/\(v)")))
            }
        }

        if let dotnet = env.which("dotnet") {
            async let sdksR = Shell.run([dotnet, "--list-sdks"], env: env.vars, timeout: 20)
            async let rtsR = Shell.run([dotnet, "--list-runtimes"], env: env.vars, timeout: 20)
            let (sdks, rts) = await (sdksR, rtsR)
            for l in sdks.out.lines {
                let parts = l.components(separatedBy: " [")
                guard parts.count == 2 else { continue }
                let base = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "]"))
                out.append(item(".NET SDK", parts[0], manager: "dotnet", path: base.appendingPath(parts[0])))
            }
            for l in rts.out.lines {
                let parts = l.components(separatedBy: " [")
                let head = parts.first?.split(separator: " ").map(String.init) ?? []
                guard parts.count == 2, head.count == 2 else { continue }
                let base = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "]"))
                out.append(item(head[0], head[1], manager: "dotnet runtime", path: base.appendingPath(head[1])))
            }
        }

        for root in [h("fvm/versions"), h(".fvm/versions")] {
            for v in dirs(root) {
                out.append(item("Flutter", v, manager: "fvm", path: root.appendingPath(v), remove: tool("fvm").map { "\($0) remove \(q(v))" }))
            }
        }
        for t in ["ghc", "cabal", "hls", "stack"] {
            for v in dirs(h(".ghcup/\(t)")) {
                out.append(item(t, v, manager: "ghcup", path: h(".ghcup/\(t)/\(v)"), remove: tool("ghcup").map { "\($0) rm \(q(t)) \(q(v))" }))
            }
        }
        for root in [h("Library/Developer/Toolchains"), "/Library/Developer/Toolchains"] {
            for tc in FS.children(root) where tc.hasSuffix(".xctoolchain") && !((try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPath(tc))) != nil) {
                let plist = NSDictionary(contentsOfFile: root.appendingPath("\(tc)/Info.plist"))
                out.append(item(tr("Swift toolchain", "Toolchain de Swift"), (plist?["Version"] as? String) ?? tc, manager: "swift.org", path: root.appendingPath(tc)))
            }
        }
        for v in dirs(h(".swiftly/toolchains")) {
            out.append(item("Swift", v, manager: "swiftly", path: h(".swiftly/toolchains/\(v)"), remove: tool("swiftly").map { "\($0) uninstall -y \(q(v))" }))
        }

        let claudeVersions = h(".local/share/claude/versions")
        let currentClaude = FS.resolve(h(".local/bin/claude")).lastPathComponent
        for v in FS.children(claudeVersions) {
            out.append(item("Claude Code", v, manager: "Claude Code", path: claudeVersions.appendingPath(v),
                            warning: v == currentClaude ? tr("This is the Claude Code version you are using right now.", "Es la versión de Claude Code que estás usando ahora.") : nil))
        }

        let android = env.vars["ANDROID_HOME"] ?? env.vars["ANDROID_SDK_ROOT"] ?? h("Library/Android/sdk")
        for (sub, label) in [("platforms", tr("Android Platform", "Plataforma de Android")), ("build-tools", tr("Android Build Tools", "Herramientas de compilación de Android")), ("ndk", "Android NDK")] {
            for v in dirs(android.appendingPath(sub)) { out.append(item(label, v, manager: "Android SDK", path: android.appendingPath("\(sub)/\(v)"))) }
        }
        for api in dirs(android.appendingPath("system-images")) {
            for variant in dirs(android.appendingPath("system-images/\(api)")) {
                for abi in dirs(android.appendingPath("system-images/\(api)/\(variant)")) {
                    out.append(item(tr("Android System Image", "Imagen de sistema de Android"), "\(api) · \(variant) · \(abi)", manager: "Android SDK",
                                    path: android.appendingPath("system-images/\(api)/\(variant)/\(abi)")))
                }
            }
        }

        for (dir, label) in [("iOS DeviceSupport", "iOS DeviceSupport"), ("watchOS DeviceSupport", "watchOS DeviceSupport"), ("tvOS DeviceSupport", "tvOS DeviceSupport")] {
            let root = h("Library/Developer/Xcode/\(dir)")
            for v in dirs(root) { out.append(item(label, v, manager: "Xcode", path: root.appendingPath(v))) }
        }
        if FS.exists("/Applications/Xcode.app") || FS.exists("/Applications/Xcode-beta.app") {
            let r = await Shell.run(["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"], env: env.vars, timeout: 30)
            if let d = parseJSON(r.out) as? [String: Any] {
                for (uuid, v) in d {
                    guard let rt = v as? [String: Any] else { continue }
                    let ident = (rt["runtimeIdentifier"] as? String ?? "").replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                    var p = item(tr("Simulator \(ident.split(separator: "-").first ?? "")", "Simulador \(ident.split(separator: "-").first ?? "")"), rt["version"] as? String ?? "?", manager: "Xcode",
                                 path: rt["path"] as? String ?? uuid, remove: "/usr/bin/xcrun simctl runtime delete \(q(uuid))")
                    if let s = rt["sizeBytes"] as? Int { p.knownSize = Int64(s) }
                    out.append(p)
                }
            }
        }
        return out
    }
}

struct ActiveRuntimesScanner: Scanner {
    static let tools: [(cmd: String, args: [String], label: String)] = [
        ("node", ["--version"], "Node.js"), ("npm", ["--version"], "npm"), ("pnpm", ["--version"], "pnpm"), ("yarn", ["--version"], "Yarn"),
        ("bun", ["--version"], "Bun"), ("deno", ["--version"], "Deno"), ("python3", ["--version"], "Python"), ("pip3", ["--version"], "pip"),
        ("uv", ["--version"], "uv"), ("pipx", ["--version"], "pipx"), ("conda", ["--version"], "Conda"), ("poetry", ["--version"], "Poetry"),
        ("ruby", ["--version"], "Ruby"), ("gem", ["--version"], "RubyGems"), ("bundle", ["--version"], "Bundler"),
        ("go", ["version"], "Go"), ("rustc", ["--version"], "Rust"), ("cargo", ["--version"], "Cargo"),
        ("java", ["-version"], "Java"), ("kotlin", ["-version"], "Kotlin"), ("gradle", ["--version"], "Gradle"), ("mvn", ["--version"], "Maven"),
        ("php", ["--version"], "PHP"), ("composer", ["--version"], "Composer"), ("dotnet", ["--version"], ".NET"),
        ("swift", ["--version"], "Swift"), ("dart", ["--version"], "Dart"), ("flutter", ["--version", "--suppress-analytics"], "Flutter"),
        ("perl", ["-e", "print $^V"], "Perl"), ("lua", ["-v"], "Lua"), ("elixir", ["--version"], "Elixir"), ("erl", ["-noshell", "-eval", "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()."], "Erlang/OTP"),
        ("ghc", ["--version"], "GHC"), ("ocaml", ["-version"], "OCaml"), ("julia", ["--version"], "Julia"), ("R", ["--version"], "R"),
        ("zig", ["version"], "Zig"), ("nim", ["--version"], "Nim"), ("crystal", ["--version"], "Crystal"), ("scala", ["-version"], "Scala"),
        ("clang", ["--version"], "Clang"), ("gcc", ["--version"], "GCC"), ("make", ["--version"], "Make"), ("cmake", ["--version"], "CMake"),
        ("git", ["--version"], "Git"), ("gh", ["--version"], "GitHub CLI"), ("docker", ["--version"], "Docker"), ("podman", ["--version"], "Podman"),
        ("kubectl", ["version", "--client"], "kubectl"), ("helm", ["version", "--short"], "Helm"), ("terraform", ["version"], "Terraform"),
        ("ollama", ["--version"], "Ollama"), ("claude", ["--version"], "Claude Code"), ("codex", ["--version"], "Codex CLI"), ("gemini", ["--version"], "Gemini CLI"),
    ]

    static let cltStubs: Set<String> = ["python3", "pip3", "git", "swift", "clang", "gcc", "make", "java", "kotlin"]

    static func manager(for path: String) -> String {
        let rules: [(String, String, String)] = [
            ("/Cellar/", "Homebrew", "Homebrew"), ("/opt/homebrew/", "Homebrew", "Homebrew"), ("/Caskroom/", "Homebrew Cask", "Homebrew Cask"),
            ("/.nvm/", "nvm", "nvm"), ("fnm", "fnm", "fnm"), ("/.volta/", "Volta", "Volta"), ("/.asdf/", "asdf", "asdf"), ("/mise/", "mise", "mise"),
            ("/.pyenv/", "pyenv", "pyenv"), ("/uv/", "uv", "uv"), ("/.rbenv/", "rbenv", "rbenv"), ("/.rvm/", "rvm", "rvm"),
            ("/.rustup/", "rustup", "rustup"), ("/.cargo/", "Cargo", "Cargo"), ("/nix/", "Nix", "Nix"), ("/opt/local/", "MacPorts", "MacPorts"),
            ("/CommandLineTools/", "Command Line Tools", "Command Line Tools"), ("/Xcode", "Xcode", "Xcode"),
            (".app/", "Included in an app", "Incluido en una app"), ("/.sdkman/", "SDKMAN!", "SDKMAN!"), ("/.ghcup/", "ghcup", "ghcup"),
            ("/.bun/", "Bun", "Bun"), ("/.deno/", "Deno", "Deno"), ("/.dotnet/", ".NET", ".NET"), ("/usr/local/share/dotnet", ".NET", ".NET"),
            ("/Library/Java/", "JDK", "JDK"), ("/.local/share/claude", "Claude Code", "Claude Code"),
            ("/usr/local/", "Installer / manual", "Instalador / manual"), ("/.local/", "User install", "Instalación de usuario"),
            ("/usr/bin/", "System (macOS)", "Sistema (macOS)"), ("/bin/", "System (macOS)", "Sistema (macOS)"),
        ]
        guard let rule = rules.first(where: { path.contains($0.0) }) else { return tr("Other", "Otro") }
        return tr(rule.1, rule.2)
    }

    func scan(_ env: ShellEnv) async -> [Package] {
        let hasCLT = FS.exists("/Library/Developer/CommandLineTools/usr/bin") || FS.exists("/Applications/Xcode.app")
        let hasJava = await Shell.run(["/usr/libexec/java_home"], env: env.vars, timeout: 5).ok
        return await withTaskGroup(of: Package?.self) { group in
            for t in Self.tools {
                guard let path = env.which(t.cmd) else { continue }
                if path.hasPrefix("/usr/bin/") && Self.cltStubs.contains(t.cmd) && !hasCLT { continue }
                if (t.cmd == "java" || t.cmd == "javac") && !hasJava { continue }
                group.addTask {
                    let r = await Shell.run([path] + t.args, env: env.vars, cwd: env.home, timeout: 15)
                    let text = r.combined
                    guard let m = text.range(of: #"\d+(\.\d+)+([\w.+-]*)?"#, options: .regularExpression) ?? text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
                    let real = FS.resolve(path)
                    let copies = env.pathDirs.map { $0.appendingPath(t.cmd) }.filter { FileManager.default.isExecutableFile(atPath: $0) }
                    var p = Package(source: Src.active, name: t.label, version: String(text[m]))
                    p.path = real
                    p.summary = Self.manager(for: real)
                    p.details.append((tr("Command", "Comando"), t.cmd))
                    p.details.append((tr("In PATH", "En el PATH"), path))
                    if real != path { p.details.append((tr("Points to", "Apunta a"), real)) }
                    if copies.count > 1 {
                        p.details.append((tr("Other copies in PATH", "Otras copias en el PATH"), copies.dropFirst().joined(separator: "\n")))
                        p.warning = tr("There are \(copies.count) copies of `\(t.cmd)` in your PATH; the first one is used.", "Hay \(copies.count) copias de `\(t.cmd)` en tu PATH; se usa la primera.")
                    }
                    if let first = text.lines.first { p.details.append((tr("Output", "Salida"), first.trimmed)) }
                    return p
                }
            }
            var out: [Package] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }
    }
}

struct LooseBinaryScanner: Scanner {
    static let managedMarkers = ["/Cellar/", "/Caskroom/", "/node_modules/", "/uv/tools/", "/pipx/", "/.cargo/", "/.bun/", "/.volta/",
                                 "/nix/store", "/mise/", "/.pyenv/", "/.rbenv/", "/Homebrew/", "/.local/share/claude/", "/.dotnet/",
                                 "/.asdf/", "/.nvm/", "/fnm/", "/.ghcup/", "/opt/homebrew/opt/", "/.deno/", "/Library/pnpm/"]

    func scan(_ env: ShellEnv) async -> [Package] {
        let dirs = [env.h(".local/bin"), env.h("bin"), "/usr/local/bin", "/usr/local/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
                    env.h("go/bin"), env.h(".jenv/versions")]
        var candidates: [(String, String)] = []
        for dir in dirs {
            for f in FS.children(dir) { candidates.append((dir, f)) }
        }
        return await withTaskGroup(of: Package?.self) { group in
            for (dir, f) in candidates {
                group.addTask {
                    let path = dir.appendingPath(f)
                    let linkDest = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                    let real = FS.resolve(path)
                    let broken = linkDest != nil && !FS.exists(real) && !real.hasPrefix("/Volumes/")
                    let ownDirs = [env.h(".local/bin"), env.h("bin"), "/usr/local/bin", "/usr/local/sbin"]
                    if !ownDirs.contains(dir) && !broken { return nil }
                    if !broken && Self.managedMarkers.contains(where: { real.contains($0) }) { return nil }
                    if !broken && FS.isDir(real) { return nil }
                    var p = Package(source: Src.loose, name: f, version: "—", context: dir.abbreviatingHome, key: broken ? "broken:" + f : nil)
                    p.path = path
                    if broken {
                        p.summary = tr("Broken link → \(linkDest!)", "Enlace roto → \(linkDest!)")
                        p.warning = tr("This link points to something that no longer exists, so it's safe to remove.", "Este enlace apunta a algo que ya no existe; es seguro eliminarlo.")
                    } else if let appRange = real.range(of: ".app/") {
                        let app = String(real[..<appRange.lowerBound]).lastPathComponent + ".app"
                        p.summary = tr("Link to the \(app) command", "Enlace al comando de \(app)")
                        p.warning = tr("Removing it only removes the Terminal command; \(app) will stay installed.", "Eliminarlo solo quita el comando de la terminal; \(app) seguirá instalada.")
                    } else if linkDest != nil {
                        p.summary = "→ " + real.abbreviatingHome
                    } else {
                        p.summary = tr("Executable file", "Archivo ejecutable")
                    }
                    if !broken, dir.hasPrefix("/usr/local") {
                        let r = await Shell.run(["/usr/sbin/pkgutil", "--file-info", path], env: env.vars, timeout: 10)
                        if let line = r.out.lines.first(where: { $0.hasPrefix("pkgid:") }) {
                            let pkg = line.dropFirst(6).trimmed
                            p.details.append((tr("Installed by", "Instalado por"), pkg))
                            p.warning = tr("Belongs to the \(pkg) installer (see “Installer packages (.pkg)”).", "Pertenece al instalador \(pkg) (ver “Instaladores .pkg”).")
                        }
                    }
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let d = attrs[.modificationDate] as? Date {
                        p.details.append((tr("Modified", "Modificado"), d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.current.locale))))
                    }
                    p.commands = [.remove: ShellCommand("rm -f \(q(path))", admin: !FS.isWritable(dir))]
                    return p
                }
            }
            var out: [Package] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }
    }
}
