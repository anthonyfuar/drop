import Foundation

private func isLink(_ p: String) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil }

private func subdirs(_ root: String) -> [String] {
    FS.children(root).filter { FS.isDir(root.appendingPath($0)) && !isLink(root.appendingPath($0)) }
}

private func dirItem(_ source: SourceInfo, _ name: String, _ version: String, context: String?, path: String,
                     summary: String? = nil, remove: String? = nil, update: String? = nil, warning: String? = nil) -> Package {
    var p = Package(source: source, name: name, version: version, context: context, key: path)
    p.path = path
    p.summary = summary ?? context
    p.warning = warning
    p.commands[.remove] = ShellCommand(remove ?? "rm -rf \(q(path))", admin: remove == nil && !FS.isWritable(path.deletingLastPathComponent))
    if let update { p.commands[.update] = ShellCommand(update) }
    return p
}

struct VMScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let src = Src.vms
        var out: [Package] = []
        let h = env.h

        if let colima = env.which("colima") {
            let r = await Shell.run([colima, "list", "--json"], env: env.vars, timeout: 20)
            for l in r.out.lines {
                guard let d = parseJSON(l) as? [String: Any], let name = d["name"] as? String else { continue }
                var p = dirItem(src, "Colima: \(name)", d["status"] as? String ?? "—", context: "Colima",
                                path: h(".colima/_lima/colima\(name == "default" ? "" : "-\(name)")"),
                                summary: tr("Virtual machine for Docker (\(d["runtime"] as? String ?? "docker")).", "Máquina virtual para Docker (\(d["runtime"] as? String ?? "docker"))."),
                                remove: "\(q(colima)) delete -f -p \(q(name))")
                if let disk = d["disk"] as? Int { p.details.append((tr("Assigned disk", "Disco asignado"), Sizes.format(Int64(disk)))) }
                out.append(p)
            }
        }
        if let lima = env.which("limactl") {
            let r = await Shell.run([lima, "list", "--json"], env: env.vars, timeout: 20)
            for l in r.out.lines {
                guard let d = parseJSON(l) as? [String: Any], let name = d["name"] as? String else { continue }
                let dir = d["dir"] as? String ?? h(".lima/\(name)")
                if dir.contains("/.colima/") { continue }
                out.append(dirItem(src, "Lima: \(name)", d["status"] as? String ?? "—", context: "Lima", path: dir,
                                   summary: tr("Linux virtual machine.", "Máquina virtual Linux."), remove: "\(q(lima)) delete -f \(q(name))"))
            }
        }
        if let podman = env.which("podman") {
            let r = await Shell.run([podman, "machine", "list", "--format", "json"], env: env.vars, timeout: 20)
            for d in parseJSON(r.out) as? [[String: Any]] ?? [] {
                guard let name = d["Name"] as? String else { continue }
                out.append(dirItem(src, "Podman: \(name)", (d["Running"] as? Bool == true) ? tr("Running", "En marcha") : tr("Stopped", "Detenida"), context: "Podman",
                                   path: h(".local/share/containers/podman/machine"), summary: tr("Podman virtual machine.", "Máquina virtual de Podman."),
                                   remove: "\(q(podman)) machine rm -f \(q(name))"))
            }
        }
        let vagrantBoxes = (env.vars["VAGRANT_HOME"] ?? h(".vagrant.d")).appendingPath("boxes")
        let vagrant = env.which("vagrant")
        for box in subdirs(vagrantBoxes) {
            let name = box.replacingOccurrences(of: "-VAGRANTSLASH-", with: "/")
            for ver in subdirs(vagrantBoxes.appendingPath(box)) {
                out.append(dirItem(src, "Vagrant: \(name)", ver, context: "Vagrant", path: vagrantBoxes.appendingPath("\(box)/\(ver)"),
                                   summary: tr("Vagrant box (image).", "Caja (imagen) de Vagrant."),
                                   remove: vagrant.map { "\(q($0)) box remove \(q(name)) --box-version \(q(ver)) --force" }))
            }
        }
        let minikube = env.which("minikube")
        for m in subdirs((env.vars["MINIKUBE_HOME"] ?? h(".minikube")).appendingPath("machines")) where !m.hasPrefix("server") {
            out.append(dirItem(src, "minikube: \(m)", "—", context: "minikube", path: h(".minikube/machines/\(m)"),
                               summary: tr("Local Kubernetes cluster.", "Clúster local de Kubernetes."), remove: minikube.map { "\(q($0)) delete -p \(q(m))" }))
        }
        if FS.isDir(h(".orbstack")) {
            out.append(dirItem(src, tr("OrbStack (data)", "OrbStack (datos)"), "—", context: "OrbStack", path: h(".orbstack"),
                               summary: tr("OrbStack settings. Its machines are managed from the OrbStack app.", "Configuración de OrbStack. Sus máquinas se gestionan desde la app."),
                               warning: tr("Uninstall OrbStack from its own app; this only shows how much space it uses.", "Desinstala OrbStack desde su app; aquí solo se muestra lo que ocupa.")))
            out[out.count - 1].commands = [:]
        }
        let avdHome = env.vars["ANDROID_AVD_HOME"] ?? (env.vars["ANDROID_USER_HOME"].map { $0.appendingPath("avd") } ?? h(".android/avd"))
        for avd in FS.children(avdHome) where avd.hasSuffix(".avd") {
            let name = String(avd.dropLast(4))
            out.append(dirItem(src, "Android: \(name)", "—", context: tr("Android emulator", "Emulador de Android"), path: avdHome.appendingPath(avd),
                               summary: tr("Android emulator (with its data).", "Emulador de Android (con sus datos)."),
                               remove: "rm -rf \(q(avdHome.appendingPath(avd))) \(q(avdHome.appendingPath("\(name).ini")))"))
        }
        if FS.exists("/Applications/Xcode.app") || FS.exists("/Applications/Xcode-beta.app") {
            let r = await Shell.run(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"], env: env.vars, timeout: 30)
            if let d = parseJSON(r.out) as? [String: Any], let byRuntime = d["devices"] as? [String: Any] {
                for (runtime, list) in byRuntime {
                    let os = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "").replacingOccurrences(of: "-", with: " ")
                    for dev in list as? [[String: Any]] ?? [] {
                        guard let udid = dev["udid"] as? String, let name = dev["name"] as? String else { continue }
                        let available = dev["isAvailable"] as? Bool ?? true
                        var p = dirItem(src, tr("Simulator: \(name)", "Simulador: \(name)"), os, context: "Xcode",
                                        path: dev["dataPath"] as? String ?? h("Library/Developer/CoreSimulator/Devices/\(udid)"),
                                        summary: available ? tr("\(os) simulator (with its apps and data).", "Simulador de \(os) (con sus apps y datos).") : tr("Simulator for a system version that’s no longer installed.", "Simulador de un sistema que ya no está instalado."),
                                        remove: "/usr/bin/xcrun simctl delete \(q(udid))")
                        p.isDependency = !available
                        if !available { p.warning = tr("It can’t be used anymore; it’s safe to delete.", "Ya no se puede usar; es seguro borrarlo.") }
                        out.append(p)
                    }
                }
            }
        }
        return out
    }
}

struct PyEnvScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let src = Src.pyenvs
        let h = env.h
        var out: [Package] = []
        func venv(_ path: String, _ name: String, _ tool: String, remove: String? = nil) {
            let py = path.appendingPath("bin/python")
            let broken = isLink(py) && !FS.exists(FS.resolve(py))
            let cfg = (try? String(contentsOfFile: path.appendingPath("pyvenv.cfg"), encoding: .utf8)) ?? ""
            let ver = cfg.lines.first { $0.hasPrefix("version") }?.components(separatedBy: "=").last?.trimmed ?? "—"
            var p = dirItem(src, name, ver, context: tool, path: path,
                            summary: broken ? tr("Broken environment: the Python it was created with no longer exists.", "Entorno roto: el Python con el que se creó ya no existe.") : tr("Virtual environment created by \(tool).", "Entorno virtual creado por \(tool)."),
                            remove: remove)
            if broken { p.warning = tr("It’s broken and can’t be used; it’s safe to delete.", "Está roto y no se puede usar; es seguro borrarlo.") }
            p.isDependency = broken
            out.append(p)
        }
        let poetry = env.vars["POETRY_VIRTUALENVS_PATH"] ?? h("Library/Caches/pypoetry/virtualenvs")
        for v in subdirs(poetry) { venv(poetry.appendingPath(v), v, "Poetry") }
        let pipenv = env.vars["WORKON_HOME"] ?? h(".local/share/virtualenvs")
        for v in subdirs(pipenv) { venv(pipenv.appendingPath(v), v, "pipenv") }
        for v in subdirs(h(".virtualenvs")) { venv(h(".virtualenvs/\(v)"), v, "virtualenvwrapper") }
        let hatch = h("Library/Application Support/hatch/env/virtual")
        for project in subdirs(hatch) {
            for v in subdirs(hatch.appendingPath(project)) {
                for e in subdirs(hatch.appendingPath("\(project)/\(v)")) { venv(hatch.appendingPath("\(project)/\(v)/\(e)"), "\(project) (\(e))", "Hatch") }
            }
        }
        let pyenv = env.vars["PYENV_ROOT"] ?? h(".pyenv")
        for base in subdirs(pyenv.appendingPath("versions")) {
            for e in subdirs(pyenv.appendingPath("versions/\(base)/envs")) {
                venv(pyenv.appendingPath("versions/\(base)/envs/\(e)"), e, "pyenv-virtualenv")
            }
        }
        let jupyter = env.which("jupyter")
        for root in [h("Library/Jupyter/kernels"), "/usr/local/share/jupyter/kernels", "/opt/homebrew/share/jupyter/kernels"] {
            for k in subdirs(root) {
                let spec = FS.json(root.appendingPath("\(k)/kernel.json")) as? [String: Any]
                let argv0 = (spec?["argv"] as? [String])?.first ?? ""
                let broken = argv0.hasPrefix("/") && !FS.exists(argv0)
                var p = dirItem(Src.pyenvs, tr("Jupyter kernel: \(spec?["display_name"] as? String ?? k)", "Kernel de Jupyter: \(spec?["display_name"] as? String ?? k)"), "—", context: "Jupyter",
                                path: root.appendingPath(k),
                                summary: broken ? tr("It points to a Python that no longer exists.", "Apunta a un Python que ya no existe.") : tr("Kernel registered in Jupyter.", "Kernel registrado en Jupyter."),
                                remove: jupyter.map { "\(q($0)) kernelspec uninstall -y \(q(k))" })
                if broken { p.warning = tr("It’s broken; it’s safe to remove.", "Está roto; es seguro quitarlo."); p.isDependency = true }
                out.append(p)
            }
        }
        return out
    }
}

struct SDKScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let src = Src.sdk
        let h = env.h
        var out: [Package] = []

        async let gcloudR = Shell.tool(env, "gcloud", ["components", "list", "--only-local-state", "--format=json", "--quiet"], timeout: 60)
        async let azR = Shell.tool(env, "az", ["extension", "list", "-o", "json"], timeout: 60)
        async let pulumiR = Shell.tool(env, "pulumi", ["plugin", "ls", "--json"], timeout: 60)
        async let arduinoCoresR = Shell.tool(env, "arduino-cli", ["core", "list", "--format", "json"], timeout: 60)
        async let arduinoLibsR = Shell.tool(env, "arduino-cli", ["lib", "list", "--format", "json"], timeout: 60)
        let (gcloud, az, pulumi, cores, libs) = await (gcloudR, azR, pulumiR, arduinoCoresR, arduinoLibsR)

        if let r = gcloud, let arr = parseJSON(r.out) as? [[String: Any]], let bin = env.which("gcloud") {
            for c in arr {
                guard let id = c["id"] as? String else { continue }
                var p = Package(source: src, name: c["name"] as? String ?? id, version: c["current_version_string"] as? String ?? "—", context: "Google Cloud SDK", key: "gcloud:" + id)
                p.summary = tr("gcloud component (\(id)).", "Componente de gcloud (\(id)).")
                if let size = c["size"] as? Int { p.knownSize = Int64(size) }
                p.commands = [.remove: ShellCommand("\(q(bin)) components remove \(q(id)) --quiet"),
                              .update: ShellCommand("\(q(bin)) components update --quiet")]
                out.append(p)
            }
        }
        if let r = az, let arr = parseJSON(r.out) as? [[String: Any]], let bin = env.which("az") {
            for e in arr {
                guard let name = e["name"] as? String else { continue }
                var p = Package(source: src, name: name, version: e["version"] as? String ?? "—", context: "Azure CLI", key: "az:" + name)
                p.path = e["path"] as? String
                p.summary = tr("Azure CLI extension.", "Extensión de Azure CLI.")
                p.commands = [.remove: ShellCommand("\(q(bin)) extension remove -n \(q(name))"),
                              .update: ShellCommand("\(q(bin)) extension update -n \(q(name))")]
                out.append(p)
            }
        }
        if let r = pulumi, let arr = parseJSON(r.out) as? [[String: Any]], let bin = env.which("pulumi") {
            for e in arr {
                guard let name = e["name"] as? String else { continue }
                let kind = e["kind"] as? String ?? "resource"
                let ver = e["version"] as? String ?? ""
                var p = Package(source: src, name: name, version: ver, context: "Pulumi (\(kind))", key: "pulumi:\(kind):\(name):\(ver)")
                if let size = e["size"] as? Int { p.knownSize = Int64(size) }
                p.summary = tr("Pulumi plugin.", "Plugin de Pulumi.")
                p.commands = [.remove: ShellCommand("\(q(bin)) plugin rm \(q(kind)) \(q(name)) \(q(ver)) --yes")]
                out.append(p)
            }
        }
        if let bin = env.which("arduino-cli") {
            let coreRoot = parseJSON(cores?.out ?? "")
            let coreList = (coreRoot as? [String: Any])?["platforms"] as? [[String: Any]] ?? coreRoot as? [[String: Any]] ?? []
            for c in coreList {
                guard let id = c["id"] as? String ?? c["ID"] as? String else { continue }
                var p = Package(source: src, name: id, version: c["installed_version"] as? String ?? c["installed"] as? String ?? "—", context: tr("Arduino (core)", "Arduino (núcleo)"), key: "arduino:" + id)
                p.summary = c["name"] as? String ?? tr("Arduino board core.", "Núcleo de placas Arduino.")
                p.commands = [.remove: ShellCommand("\(q(bin)) core uninstall \(q(id))"), .update: ShellCommand("\(q(bin)) core upgrade \(q(id))")]
                out.append(p)
            }
            for e in (parseJSON(libs?.out ?? "") as? [String: Any])?["installed_libraries"] as? [[String: Any]] ?? [] {
                guard let lib = e["library"] as? [String: Any], let name = lib["name"] as? String else { continue }
                var p = Package(source: src, name: name, version: lib["version"] as? String ?? "—", context: tr("Arduino (library)", "Arduino (librería)"), key: "arduinolib:" + name)
                p.path = lib["install_dir"] as? String
                p.commands = [.remove: ShellCommand("\(q(bin)) lib uninstall \(q(name))"), .update: ShellCommand("\(q(bin)) lib upgrade \(q(name))")]
                out.append(p)
            }
        }

        let pio = env.vars["PLATFORMIO_CORE_DIR"] ?? h(".platformio")
        for kind in ["platforms", "packages"] {
            for d in subdirs(pio.appendingPath(kind)) {
                out.append(dirItem(src, d, "—", context: kind == "platforms" ? tr("PlatformIO (platform)", "PlatformIO (plataforma)") : tr("PlatformIO (package)", "PlatformIO (paquete)"), path: pio.appendingPath("\(kind)/\(d)")))
            }
        }
        let idf = env.vars["IDF_TOOLS_PATH"] ?? h(".espressif")
        for tool in subdirs(idf.appendingPath("tools")) {
            for ver in subdirs(idf.appendingPath("tools/\(tool)")) {
                out.append(dirItem(src, tool, ver, context: "ESP-IDF", path: idf.appendingPath("tools/\(tool)/\(ver)")))
            }
        }
        for d in subdirs(h("esp")) where d.hasPrefix("esp-idf") {
            out.append(dirItem(src, d, "—", context: "ESP-IDF", path: h("esp/\(d)"), summary: tr("Espressif’s framework for ESP32.", "Framework de Espressif para ESP32.")))
        }
        for pkg in subdirs(h("Library/Arduino15/packages")) {
            out.append(dirItem(src, pkg, "—", context: tr("Arduino (package)", "Arduino (paquete)"), path: h("Library/Arduino15/packages/\(pkg)")))
        }
        for v in subdirs("/Applications/Unity/Hub/Editor") {
            out.append(dirItem(src, "Unity", v, context: "Unity Hub", path: "/Applications/Unity/Hub/Editor/\(v)",
                               summary: tr("Unity editor.", "Editor de Unity."), warning: tr("If you have Unity Hub, it’s better to uninstall it from there.", "Mejor desinstálalo desde Unity Hub si lo tienes.")))
        }
        let godot = h("Library/Application Support/Godot/export_templates")
        for v in subdirs(godot) { out.append(dirItem(src, tr("Godot export templates", "Plantillas de exportación de Godot"), v, context: "Godot", path: godot.appendingPath(v))) }
        for app in FS.children("/Applications") where app.hasPrefix("Xcode") && app.hasSuffix(".app") {
            let path = "/Applications/\(app)"
            let ver = (NSDictionary(contentsOfFile: path.appendingPath("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "—"
            out.append(dirItem(src, app.replacingOccurrences(of: ".app", with: ""), ver, context: "Xcode", path: path,
                               summary: tr("Apple’s development environment.", "Entorno de desarrollo de Apple."),
                               remove: env.which("xcodes").map { "\(q($0)) uninstall \(q(ver))" },
                               warning: tr("It takes up many GB. If it’s your only Xcode, you won’t be able to build Apple apps until you reinstall it.", "Ocupa muchos GB. Si es tu único Xcode, no podrás compilar apps de Apple hasta reinstalarlo.")))
        }
        let mix = env.vars["MIX_HOME"] ?? h(".mix")
        for a in FS.children(mix.appendingPath("archives")) {
            out.append(dirItem(src, a, "—", context: tr("Mix (archive)", "Mix (archivo)"), path: mix.appendingPath("archives/\(a)"),
                               remove: env.which("mix").map { "\(q($0)) archive.uninstall --force \(q(a))" }))
        }
        for e in FS.children(mix.appendingPath("escripts")) {
            out.append(dirItem(src, e, "—", context: "Mix (escript)", path: mix.appendingPath("escripts/\(e)")))
        }
        for p in subdirs(h(".nimble/pkgs2")) {
            let parts = p.split(separator: "-")
            out.append(dirItem(src, parts.first.map(String.init) ?? p, parts.count > 1 ? String(parts[1]) : "—", context: "nimble (Nim)",
                               path: h(".nimble/pkgs2/\(p)"), remove: env.which("nimble").map { "\(q($0)) uninstall -y \(q(String(parts.first ?? "")))" }))
        }
        for b in FS.children(h(".jbang/bin")) where !b.hasPrefix("jbang") {
            out.append(dirItem(src, b, "—", context: "jbang", path: h(".jbang/bin/\(b)"),
                               remove: env.which("jbang").map { "\(q($0)) app uninstall \(q(b))" }))
        }
        let cs = h("Library/Application Support/Coursier/bin")
        for b in FS.children(cs) where !b.hasPrefix(".") {
            out.append(dirItem(src, b, "—", context: "Coursier (Scala)", path: cs.appendingPath(b),
                               remove: env.which("cs").map { "\(q($0)) uninstall \(q(b))" }, update: env.which("cs").map { "\(q($0)) update \(q(b))" }))
        }
        let pixi = env.vars["PIXI_HOME"] ?? h(".pixi")
        for e in subdirs(pixi.appendingPath("envs")) {
            out.append(dirItem(src, e, "—", context: "pixi", path: pixi.appendingPath("envs/\(e)"),
                               remove: env.which("pixi").map { "\(q($0)) global uninstall \(q(e))" }, update: env.which("pixi").map { "\(q($0)) global update \(q(e))" }))
        }
        for root in [env.vars["PKGX_DIR"] ?? h(".pkgx"), h("Library/Packages")] where FS.isDir(root) {
            for domain in subdirs(root) {
                for v in subdirs(root.appendingPath(domain)) where v.hasPrefix("v") {
                    out.append(dirItem(src, domain, String(v.dropFirst()), context: "pkgx", path: root.appendingPath("\(domain)/\(v)")))
                }
            }
        }
        if let r = await Shell.tool(env, "dotnet", ["workload", "list"], timeout: 30), let bin = env.which("dotnet") {
            var started = false
            for l in r.out.lines {
                if l.hasPrefix("---") { started = true; continue }
                let c = l.split(whereSeparator: \.isWhitespace).map(String.init)
                guard started, c.count >= 2, !l.lowercased().contains("use `dotnet") else { continue }
                var p = Package(source: src, name: c[0], version: c[1], context: ".NET workload", key: "workload:" + c[0])
                p.commands = [.remove: ShellCommand("\(q(bin)) workload uninstall \(q(c[0]))", admin: !FS.isWritable("/usr/local/share/dotnet")),
                              .update: ShellCommand("\(q(bin)) workload update", admin: !FS.isWritable("/usr/local/share/dotnet"))]
                out.append(p)
            }
        }
        return out
    }
}

struct ExtraVersionsScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        let src = Src.versions
        let h = env.h
        var out: [Package] = []
        func add(_ tool: String, _ manager: String, _ root: String, filter: (String) -> Bool = { _ in true }, remove: ((String) -> String?)? = nil) {
            for v in subdirs(root) where filter(v) {
                out.append(dirItem(src, tool, v, context: manager, path: root.appendingPath(v), summary: manager, remove: remove?(v)))
            }
        }
        let t = { (n: String) in env.which(n).map(q) }
        add("Node.js", "nvs", (env.vars["NVS_HOME"] ?? h(".nvs")).appendingPath("node"))
        add("Go", "gvm", h(".gvm/gos"), remove: { v in t("gvm").map { _ in "rm -rf \(q(h(".gvm/gos/\(v)")))" } })
        add("Java (JDK)", "jabba", (env.vars["JABBA_HOME"] ?? h(".jabba")).appendingPath("jdk"), remove: { v in t("jabba").map { "\($0) uninstall \(q(v))" } })
        add("Java (JDK)", "Coursier", h("Library/Caches/Coursier/jvm"))
        add("Java (JDK)", tr("Gradle (downloaded)", "Gradle (descargado)"), h(".gradle/jdks"))
        add("Elixir", "kiex", h(".kiex/elixirs"), remove: { v in t("kiex").map { "\($0) uninstall \(q(v))" } })
        add("Nim", "choosenim", h(".choosenim/toolchains"))
        add("Zig", "zvm", env.vars["ZVM_PATH"] ?? h(".zvm"), filter: { $0.first?.isNumber == true || $0 == "master" }, remove: { v in t("zvm").map { "\($0) rm \(q(v))" } })
        add("Julia", "juliaup", h(".julia/juliaup"), filter: { $0.hasPrefix("julia-") })
        add("Perl", "plenv", h(".plenv/versions"), remove: { v in t("plenv").map { "\($0) uninstall -f \(q(v))" } })
        add("Perl", "perlbrew", (env.vars["PERLBREW_ROOT"] ?? h("perl5/perlbrew")).appendingPath("perls"), remove: { v in t("perlbrew").map { "\($0) uninstall \(q(v))" } })
        add("Kotlin/Native", "Kotlin", h(".konan"), filter: { $0.hasPrefix("kotlin-native") })
        add("Terraform", "tfenv", h(".tfenv/versions"), remove: { v in t("tfenv").map { "\($0) uninstall \(q(v))" } })
        for tool in ["Terraform", "OpenTofu", "Terragrunt", "Atmos"] {
            add(tool, "tenv", h(".tenv/\(tool)"), remove: { v in t("tenv").map { "\($0) \(tool == "Terraform" ? "tf" : tool == "OpenTofu" ? "tofu" : tool == "Terragrunt" ? "tg" : "at") uninstall \(q(v))" } })
        }
        let stackPrograms = (env.vars["STACK_ROOT"] ?? h(".stack")).appendingPath("programs")
        for arch in subdirs(stackPrograms) {
            add("GHC", "Stack", stackPrograms.appendingPath(arch), filter: { $0.hasPrefix("ghc") })
        }
        let proto = env.vars["PROTO_HOME"] ?? h(".proto")
        for tool in subdirs(proto.appendingPath("tools")) {
            add(tool, "proto", proto.appendingPath("tools/\(tool)"), filter: { $0.first?.isNumber == true },
                remove: { v in t("proto").map { "\($0) uninstall \(q(tool)) \(q(v)) --yes" } })
        }
        let vfox = (env.vars["VFOX_HOME"] ?? h(".version-fox")).appendingPath("cache")
        for sdk in subdirs(vfox) {
            add(sdk, "vfox", vfox.appendingPath(sdk), filter: { $0.hasPrefix("v-") }, remove: { v in t("vfox").map { "\($0) uninstall \(q(sdk + "@" + v.dropFirst(2)))" } })
        }
        add("Erlang/OTP", "kerl", h(".kerl/builds"), remove: { v in t("kerl").map { "\($0) delete build \(q(v))" } })
        return out
    }
}
