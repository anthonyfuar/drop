import Foundation

struct ProcResult: Sendable {
    var status: Int32
    var out: String
    var err: String
    var ok: Bool { status == 0 }
    var combined: String { [out, err].filter { !$0.isEmpty }.joined(separator: "\n") }
}

struct ShellEnv: Sendable {
    let home: String
    let vars: [String: String]
    let pathDirs: [String]

    var path: String { pathDirs.joined(separator: ":") }

    func which(_ tool: String) -> String? {
        for dir in pathDirs {
            let p = dir.appendingPath(tool)
            if FileManager.default.isExecutableFile(atPath: p), !FS.isDir(p) { return p }
        }
        return nil
    }

    func has(_ tool: String) -> Bool { which(tool) != nil }

    func h(_ rel: String) -> String { home.appendingPath(rel) }

    static func resolve() async -> ShellEnv {
        let home = NSHomeDirectory()
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"] ?? "/bin/zsh"

        var loginDirs: [String] = []
        let probe = await Shell.run([shell, "-ilc", "printf '__DROP__%s__END__' \"$PATH\""],
                                    env: base, timeout: 6)
        if let r = probe.out.range(of: "__DROP__"), let e = probe.out.range(of: "__END__", range: r.upperBound..<probe.out.endIndex) {
            loginDirs = probe.out[r.upperBound..<e.lowerBound].split(separator: ":").map(String.init)
        }

        let known = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
            "/opt/local/bin", "/opt/local/sbin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
            "\(home)/go/bin", "\(home)/.volta/bin", "\(home)/.nix-profile/bin", "/nix/var/nix/profiles/default/bin",
            "\(home)/.dotnet/tools", "/usr/local/share/dotnet", "\(home)/.dotnet",
            "\(home)/.pub-cache/bin", "\(home)/fvm/default/bin", "\(home)/flutter/bin", "\(home)/development/flutter/bin",
            "\(home)/.ghcup/bin", "\(home)/.cabal/bin", "\(home)/.juliaup/bin", "\(home)/Library/pnpm",
            "\(home)/.yarn/bin", "\(home)/.config/yarn/global/node_modules/.bin",
            "\(home)/.composer/vendor/bin", "\(home)/.config/composer/vendor/bin",
            "\(home)/Library/Application Support/Herd/bin", "\(home)/.pyenv/bin", "\(home)/.rbenv/bin",
            "\(home)/.local/share/mise/shims", "\(home)/.asdf/bin", "\(home)/.asdf/shims", "\(home)/.rvm/bin",
            "\(home)/miniconda3/condabin", "\(home)/anaconda3/condabin", "\(home)/miniforge3/condabin",
            "\(home)/mambaforge/condabin", "/opt/homebrew/Caskroom/miniconda/base/condabin",
            "/opt/homebrew/Caskroom/miniforge/base/condabin", "/opt/miniconda3/condabin", "/opt/anaconda3/condabin",
            "\(home)/.sdkman/bin", "\(home)/.opam/default/bin", "\(home)/.luarocks/bin", "\(home)/.krew/bin",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin",
            "/Applications/Cursor.app/Contents/Resources/app/bin",
            "/Applications/Windsurf.app/Contents/Resources/app/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/Applications/Ollama.app/Contents/Resources",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        var dirs: [String] = []
        for d in loginDirs + known where !d.isEmpty && !seen.contains(d) {
            seen.insert(d)
            if FS.isDir(d) { dirs.append(d) }
        }

        base["PATH"] = dirs.joined(separator: ":")
        base["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        base["HOMEBREW_NO_ENV_HINTS"] = "1"
        base["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        base["HOMEBREW_COLOR"] = nil
        base["NO_COLOR"] = "1"
        base["TERM"] = "dumb"
        base["CI"] = "1"
        base["npm_config_fund"] = "false"
        base["npm_config_update_notifier"] = "false"
        base["npm_config_yes"] = "true"
        base["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        base["PIP_NO_INPUT"] = "1"
        base["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        base["DOTNET_NOLOGO"] = "1"
        base["LANG"] = base["LANG"] ?? "en_US.UTF-8"
        base["SUDO_ASKPASS"] = Askpass.install()
        return ShellEnv(home: home, vars: base, pathDirs: dirs)
    }
}

enum Askpass {
    static func install() -> String {
        let dir = NSHomeDirectory().appendingPath("Library/Application Support/Drop")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir.appendingPath("askpass.sh")
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'display dialog "\(tr("Drop needs your administrator password to finish.", "Drop necesita tu contraseña de administrador para terminar."))" default answer "" with hidden answer with title "Drop" with icon caution buttons {"\(tr("Cancel", "Cancelar"))", "OK"} default button "OK"' -e 'text returned of result'
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o700)
        return path
    }
}

enum Shell {
    static func run(_ argv: [String], env: [String: String], cwd: String? = nil, timeout: TimeInterval = 45) async -> ProcResult {
        await withCheckedContinuation { cont in
            let tmp = FileManager.default.temporaryDirectory
            let outURL = tmp.appendingPathComponent("drop-\(UUID().uuidString).out")
            let errURL = tmp.appendingPathComponent("drop-\(UUID().uuidString).err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            guard let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL) else {
                cont.resume(returning: ProcResult(status: -1, out: "", err: "tmp"))
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            p.environment = env
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = outH
            p.standardError = errH

            let finish: @Sendable (Int32) -> Void = { status in
                try? outH.close(); try? errH.close()
                let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
                let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
                cont.resume(returning: ProcResult(status: status, out: out, err: err))
            }
            p.terminationHandler = { proc in finish(proc.terminationStatus) }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                try? outH.close(); try? errH.close()
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
                cont.resume(returning: ProcResult(status: -1, out: "", err: error.localizedDescription))
                return
            }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    static func sh(_ script: String, env: ShellEnv, timeout: TimeInterval = 45) async -> ProcResult {
        await run(["/bin/zsh", "-f", "-c", script], env: env.vars, cwd: env.home, timeout: timeout)
    }

    static func tool(_ env: ShellEnv, _ name: String, _ args: [String], timeout: TimeInterval = 45) async -> ProcResult? {
        guard let path = env.which(name) else { return nil }
        return await run([path] + args, env: env.vars, cwd: env.home, timeout: timeout)
    }

    static func stream(_ script: String, env: ShellEnv, onOutput: @escaping @Sendable (String) -> Void) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-f", "-c", script]
            p.environment = env.vars
            p.currentDirectoryURL = URL(fileURLWithPath: env.home)
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                onOutput(String(decoding: d, as: UTF8.self))
            }
            p.terminationHandler = { proc in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: proc.terminationStatus)
                }
            }
            do { try p.run() } catch {
                onOutput("Error: \(error.localizedDescription)\n")
                cont.resume(returning: -1)
            }
        }
    }

    private static let adminQueue = DispatchQueue(label: "app.drop.admin")

    static func admin(_ script: String, env: ShellEnv, prompt: String = tr("Drop needs administrator permission to finish.", "Drop necesita permisos de administrador para terminar.")) async -> ProcResult {
        let full = "export PATH=\(q(env.path)); export HOME=\(q(env.home)); export HOMEBREW_NO_AUTO_UPDATE=1; " +
            "export npm_config_yes=true; cd \(q(env.home)); ( \(script) ) 2>&1"
        let escape = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let privileges = " with prompt \"\(escape(prompt))\" with administrator privileges"
        let source = "do shell script \"\(escape(full))\"\(privileges)"
        return await withCheckedContinuation { cont in
            adminQueue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 1
                    let msg = error[NSAppleScript.errorMessage] as? String ?? tr("Unknown error", "Error desconocido")
                    cont.resume(returning: ProcResult(status: Int32(truncatingIfNeeded: code == 0 ? 1 : code), out: "",
                                                      err: "\(msg.replacingOccurrences(of: "\r", with: "\n")) (\(code))"))
                } else {
                    let out = (result?.stringValue ?? "").replacingOccurrences(of: "\r", with: "\n")
                    cont.resume(returning: ProcResult(status: 0, out: out, err: ""))
                }
            }
        }
    }

    static func isCancel(_ r: ProcResult) -> Bool { r.err.contains("(-128)") }

    static func looksLikePermissionError(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["eacces", "permission denied", "operation not permitted", "must be run as root",
                "insufficient permissions", "you don't have write permissions", "requires root",
                "not writable", "sudo:", "access is denied", "errno 13"].contains { l.contains($0) }
    }
}
