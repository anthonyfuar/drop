import Foundation

enum AdminScan {
    static let source = SourceInfo(id: "admin", en: "Deep scan", es: "Escaneo profundo", symbol: "lock.shield", group: .system, removeEn: "Remove", removeEs: "Eliminar")

    static func userDevDirs(_ env: ShellEnv) -> [String] {
        [".npm", ".cache", ".config", ".local", ".cargo", ".rustup", ".gem", ".composer", ".bun", ".yarn", ".nvm", ".node-gyp",
         ".pnpm-store", "Library/pnpm", ".cocoapods", ".gradle", ".m2", ".docker", "go", ".pyenv", ".rbenv", ".volta", ".deno",
         ".pub-cache", ".ollama", ".bundle", ".vscode/extensions", ".cursor/extensions", "Library/Caches/pip", "Library/Caches/Yarn",
         "Library/Caches/Homebrew", "Library/Caches/node-gyp", "Library/Python", ".android", ".kube", ".terraform.d"]
            .map { env.h($0) }.filter { FS.exists($0) }
    }

    static let systemDirs = [
        "/Library/Developer/CommandLineTools", "/Library/Developer/CoreSimulator/Volumes", "/Library/Developer/CoreSimulator/Images",
        "/Library/Developer/CoreSimulator/Cryptex", "/usr/local/lib/node_modules", "/usr/local/aws-cli", "/usr/local/share/dotnet",
        "/usr/local/go", "/usr/local/n", "/usr/local/Cellar", "/usr/local/Homebrew", "/usr/local/texlive", "/Library/TeX",
        "/Library/Frameworks/Mono.framework", "/Library/Frameworks/R.framework", "/nix",
    ]

    static let dockerDiskSuffix = "/Library/Containers/com.docker.docker/Data/vms/0/data"
    static let xcodeArchivesSuffix = "/Library/Developer/Xcode/Archives"
    static let simulatorDevicesSuffix = "/Library/Developer/CoreSimulator/Devices"
    static let simulatorProfiles = "/Library/Developer/CoreSimulator/Profiles"

    static func script(_ env: ShellEnv) -> String {
        script(env, deep: false)
    }

    static func script(_ env: ShellEnv, deep: Bool) -> String {
        let rootDirs = ["/var/root/.npm", "/var/root/.cache", "/var/root/Library/Caches", "/var/root/.cargo", "/var/root/.gem",
                        "/var/root/.node-gyp", "/var/root/.yarn", "/var/root/.pnpm-store", "/var/root/.bun", "/var/root/.composer",
                        "/var/root/.config/yarn", "/var/root/.local", "/var/root/.gradle", "/var/root/.m2", "/var/root/go"]
        let user = userDevDirs(env).map(q).joined(separator: " ")
        var deepPart = ""
        if deep {
            let deepDirs = [env.home + dockerDiskSuffix, env.home + xcodeArchivesSuffix, env.home + simulatorDevicesSuffix, simulatorProfiles]
            let orb = q(env.h("Library/Group Containers") + "/") + "*dev.orbstack"
            deepPart = """
            for d in \(deepDirs.map(q).joined(separator: " ")) \(orb); do
              [ -e "$d" ] || continue
              printf 'system\\t%s\\t%s\\n' "$d" "$(du -skx "$d" 2>/dev/null | cut -f1)"
            done

            """
        }
        return """
        for d in \(rootDirs.map(q).joined(separator: " ")); do
          [ -e "$d" ] && printf 'rootcache\\t%s\\t%s\\n' "$d" "$(du -skx "$d" 2>/dev/null | cut -f1)"
        done
        n=$(ls /cores 2>/dev/null | grep -c '^core')
        [ "$n" -gt 0 ] && printf 'cores\\t/cores\\t%s\\n' "$(du -sk /cores 2>/dev/null | cut -f1)"
        for d in \(user.isEmpty ? "''" : user); do
          [ -e "$d" ] || continue
          n=$(find "$d" -xdev -user root 2>/dev/null | head -20000 | wc -l | tr -d ' ')
          [ "$n" -gt 0 ] && printf 'rootowned\\t%s\\t%s\\n' "$d" "$n"
        done
        for d in \(systemDirs.map(q).joined(separator: " ")) /Library/Frameworks/Python.framework/Versions/* /Library/Java/JavaVirtualMachines/* /Library/Developer/Toolchains/* "/Applications/Python "* /opt/*; do
          [ -e "$d" ] || continue
          case "$d" in /opt/homebrew|*/Current) continue;; esac
          printf 'system\\t%s\\t%s\\n' "$d" "$(du -skx "$d" 2>/dev/null | cut -f1)"
        done
        \(deepPart)exit 0
        """
    }

    static func run(_ env: ShellEnv) async -> (packages: [Package], error: String?, cancelled: Bool) {
        await run(env, deep: false)
    }

    static func run(_ env: ShellEnv, deep: Bool) async -> (packages: [Package], error: String?, cancelled: Bool) {
        let r = await Shell.admin(script(env, deep: deep), env: env,
                                  prompt: tr("Drop wants to check system folders and administrator files. Use Touch ID or your password to continue.",
                                             "Drop quiere revisar carpetas del sistema y archivos de administrador. Usa Touch ID o tu contraseña para continuar."))
        if Shell.isCancel(r) { return ([], nil, true) }
        guard r.ok else { return ([], r.err, false) }
        return (parse(r.out, env: env), nil, false)
    }

    static func parse(_ text: String, env: ShellEnv) -> [Package] {
        let group = getgrgid(getgid()).map { String(cString: $0.pointee.gr_name) } ?? "staff"
        let user = NSUserName()
        return text.lines.compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 3 else { return nil }
            let kind = c[0], path = c[1]
            let kb = Int64(c[2].trimmed)
            switch kind {
            case "rootcache":
                let shown = path.replacingOccurrences(of: "/var/root/", with: "~root/")
                var p = Package(source: source, name: tr("Root cache: ", "Caché de root: ") + shown, version: "—", key: "rootcache:" + path)
                p.path = path
                p.knownSize = kb.map { $0 * 1024 }
                p.summary = tr("Left behind when something was installed with sudo (npm, pip, gem…). It’s safe to delete.",
                               "Quedó al instalar algo con sudo (npm, pip, gem…). Es segura de borrar.")
                p.details.append((tr("Safety", "Seguridad"), tr("Safe to delete", "Segura de borrar")))
                p.commands[.remove] = ShellCommand("rm -rf \(q(path))", admin: true)
                return p
            case "cores":
                var p = Package(source: source, name: tr("Crash memory dumps (/cores)", "Volcados de memoria (/cores)"), version: "—", key: "cores:" + path)
                p.path = path
                p.knownSize = kb.map { $0 * 1024 }
                p.summary = tr("Copies of the memory of programs that crashed. They can take up several GB and are safe to delete.",
                               "Copias de la memoria de programas que se cerraron de golpe. Pueden ocupar varios GB y son seguras de borrar.")
                p.commands[.remove] = ShellCommand("rm -f /cores/core.*", admin: true)
                return p
            case "rootowned":
                let n = Int(c[2].trimmed) ?? 0
                let count = "\(n)\(n >= 20000 ? "+" : "")"
                var p = Package(source: source, name: tr("Broken permissions in ", "Permisos rotos en ") + path.abbreviatingHome,
                                version: tr("\(count) files", "\(count) archivos"), key: "owned:" + path)
                p.path = path
                p.summary = tr("These files belong to root because sudo was used. They often cause “EACCES / permission denied” errors.",
                               "Estos archivos pertenecen a root porque se usó sudo. Suelen causar errores “EACCES / permission denied”.")
                p.warning = tr("“Repair” gives these files back to your user (\(user)). Nothing is deleted.",
                               "“Reparar” devuelve estos archivos a tu usuario (\(user)). No borra nada.")
                p.commands[.repair] = ShellCommand("chown -R \(q(user)):\(group) \(q(path))", admin: true)
                return p
            default:
                return systemPackage(path: path, kb: kb)
            }
        }
    }

    private static func systemPackage(path: String, kb: Int64?) -> Package {
        var p = Package(source: source, name: path.lastPathComponent, version: "—", key: path)
        p.path = path
        p.knownSize = kb.map { $0 * 1024 }
        var remove: String? = "rm -rf \(q(path))"
        switch path {
        case let x where x.hasSuffix(dockerDiskSuffix):
            p.name = tr("Docker Desktop disk", "Disco de Docker Desktop")
            p.summary = tr("The virtual disk where Docker Desktop keeps all your images, containers and volumes. To make it smaller, use Docker Desktop › Settings › Resources, or run `docker system prune` in the terminal.",
                           "El disco virtual donde Docker Desktop guarda todas tus imágenes, contenedores y volúmenes. Para reducirlo usa Docker Desktop › Settings › Resources, o ejecuta `docker system prune` en la terminal.")
            remove = nil
        case let x where x.contains("/Library/Group Containers/") && x.hasSuffix("dev.orbstack"):
            p.name = tr("OrbStack data", "Datos de OrbStack")
            p.summary = tr("Where OrbStack keeps its Linux machines, containers and images. Manage it from the OrbStack app.",
                           "Donde OrbStack guarda sus máquinas Linux, contenedores e imágenes. Se gestiona desde la app de OrbStack.")
            remove = nil
        case let x where x.hasSuffix(xcodeArchivesSuffix):
            p.name = tr("Xcode archives", "Archivos de Xcode (Archives)")
            p.summary = tr("Builds of your apps saved each time you used Product › Archive in Xcode. Review and delete old ones from Xcode › Window › Organizer.",
                           "Compilaciones de tus apps guardadas cada vez que usaste Product › Archive en Xcode. Revisa y borra las viejas desde Xcode › Window › Organizer.")
            remove = nil
        case let x where x.hasSuffix(simulatorDevicesSuffix):
            p.name = tr("iOS simulator devices", "Dispositivos del simulador de iOS")
            p.summary = tr("The simulated iPhones and iPads Xcode created, with their apps and data. To remove the ones that no longer work, run `xcrun simctl delete unavailable` in the terminal.",
                           "Los iPhone y iPad simulados que creó Xcode, con sus apps y datos. Para quitar los que ya no sirven, ejecuta `xcrun simctl delete unavailable` en la terminal.")
            remove = nil
        case simulatorProfiles:
            p.name = tr("iOS simulator profiles", "Perfiles del simulador de iOS")
            p.summary = tr("Descriptions of the devices Xcode can simulate. They’re small and managed by Xcode.",
                           "Descripciones de los dispositivos que Xcode puede simular. Son pequeñas y las gestiona Xcode.")
            remove = nil
        case "/Library/Developer/CommandLineTools":
            p.name = tr("Apple Command Line Tools", "Command Line Tools de Apple")
            p.summary = tr("They include git, clang, make and swift. Almost every programming tool needs them.",
                           "Incluyen git, clang, make y swift. Casi todas las herramientas de programación las necesitan.")
            p.warning = tr("If you remove them, git, Homebrew and many other tools will stop working until you reinstall them with `xcode-select --install`.",
                           "Si las quitas dejarán de funcionar git, Homebrew y muchas herramientas hasta reinstalarlas con `xcode-select --install`.")
        case let x where x.hasPrefix("/Library/Developer/CoreSimulator"):
            p.name = tr("iOS simulators (\(path.lastPathComponent))", "Simuladores de iOS (\(path.lastPathComponent))")
            p.summary = tr("Simulator systems downloaded by Xcode. Manage them from Xcode › Settings › Platforms.",
                           "Sistemas de simulador descargados por Xcode. Se gestionan desde Xcode › Settings › Platforms.")
            remove = nil
        case "/usr/local/lib/node_modules":
            p.name = tr("Global npm packages (system)", "Paquetes globales de npm (sistema)")
            p.summary = tr("The folder for packages installed with `npm install -g`. Each package shows up under “npm (global)”.",
                           "Carpeta de los paquetes de `npm install -g`. Cada paquete aparece en “npm (global)”.")
            remove = nil
        case "/usr/local/aws-cli":
            p.name = "AWS CLI v2"
            p.summary = tr("Installed with Amazon’s official installer.", "Instalada con el instalador oficial de Amazon.")
            remove = "rm -rf /usr/local/aws-cli; rm -f /usr/local/bin/aws /usr/local/bin/aws_completer"
        case "/usr/local/share/dotnet":
            p.name = tr(".NET (system install)", ".NET (instalación del sistema)")
            p.summary = tr(".NET SDKs and runtimes installed with Microsoft’s installer.",
                           "SDKs y runtimes de .NET instalados con el instalador de Microsoft.")
            remove = "rm -rf /usr/local/share/dotnet; rm -f /etc/paths.d/dotnet /etc/paths.d/dotnet-cli-tools; rm -f /usr/local/bin/dotnet"
        case "/usr/local/go":
            p.name = tr("Go (official installer)", "Go (instalador oficial)")
            p.summary = tr("Go installed with the .pkg from go.dev.", "Go instalado con el .pkg de go.dev.")
            remove = "rm -rf /usr/local/go; rm -f /etc/paths.d/go"
        case "/usr/local/n":
            p.name = tr("n (Node versions)", "n (versiones de Node)")
            p.summary = tr("Node versions downloaded by the n tool.", "Versiones de Node descargadas por la herramienta n.")
        case "/Library/Frameworks/Mono.framework":
            p.name = "Mono"
            p.summary = tr("An older .NET environment (Mono/Xamarin).", "Entorno de .NET antiguo (Mono/Xamarin).")
            remove = "rm -rf /Library/Frameworks/Mono.framework; pkgutil --pkgs | grep -i mono | while read -r id; do pkgutil --forget \"$id\"; done"
        case "/Library/Frameworks/R.framework":
            p.name = "R (CRAN)"
            p.summary = tr("The R language, installed with the CRAN installer.", "Lenguaje R instalado con el instalador de CRAN.")
            remove = "rm -rf /Library/Frameworks/R.framework /Applications/R.app; pkgutil --pkgs | grep '^org.R-project' | while read -r id; do pkgutil --forget \"$id\"; done"
        case "/nix":
            p.name = tr("Nix (store)", "Nix (almacén)")
            p.summary = tr("Everything installed with Nix. To remove it, use Nix’s official uninstaller.",
                           "Todo lo instalado con Nix. Para quitarlo usa el desinstalador oficial de Nix.")
            remove = nil
        case "/usr/local/Cellar", "/usr/local/Homebrew":
            p.name = tr("Homebrew for Intel (\(path.lastPathComponent))", "Homebrew para Intel (\(path.lastPathComponent))")
            p.summary = tr("An older Homebrew install for Intel processors / Rosetta.",
                           "Instalación antigua de Homebrew para procesadores Intel / Rosetta.")
            p.warning = tr("If you still use Homebrew in Intel mode, don’t delete it.",
                           "Si todavía usas Homebrew en modo Intel, no la borres.")
        case let x where x.hasPrefix("/Library/Frameworks/Python.framework/Versions/"):
            let v = path.lastPathComponent
            p.name = "Python \(v) (python.org)"
            p.version = v
            p.summary = tr("Installed with the official python.org installer.", "Instalado con el instalador oficial de python.org.")
            remove = "rm -rf \(q(path)) \(q("/Applications/Python \(v)")); find /usr/local/bin -lname '*Python.framework/Versions/\(v)*' -delete 2>/dev/null; pkgutil --pkgs | grep -i 'org.python.Python.*\(v.replacingOccurrences(of: ".", with: ""))' | while read -r id; do pkgutil --forget \"$id\"; done"
        case let x where x.hasPrefix("/Library/Java/JavaVirtualMachines/"):
            p.name = "Java: " + path.lastPathComponent
            p.summary = tr("A JDK installed for the whole system.", "JDK instalado para todo el sistema.")
        case let x where x.hasPrefix("/Library/Developer/Toolchains/"):
            p.name = tr("Swift toolchain: ", "Toolchain de Swift: ") + path.lastPathComponent
            p.summary = tr("A swift.org toolchain installed for the whole system.",
                           "Toolchain de swift.org instalado para todo el sistema.")
        case let x where x.hasPrefix("/Applications/Python "):
            p.name = path.lastPathComponent + tr(" (python.org shortcuts)", " (accesos de python.org)")
            p.summary = tr("A folder of shortcuts created by the python.org installer.",
                           "Carpeta de accesos directos que crea el instalador de python.org.")
        case let x where x.hasPrefix("/opt/"):
            p.name = path
            p.summary = tr("Software installed by hand in /opt.", "Software instalado a mano en /opt.")
            if path == "/opt/local" {
                p.warning = tr("This is MacPorts. Only delete it if you no longer use it.",
                               "Es MacPorts. Bórralo solo si ya no lo usas.")
            } else {
                p.warning = tr("Check what this is before deleting it: Drop doesn’t know which program installed it.",
                               "Revisa qué es antes de borrarlo: Drop no sabe qué programa lo instaló.")
            }
        default:
            p.summary = tr("A system-wide installation.", "Instalación a nivel de sistema.")
        }
        if let remove { p.commands[.remove] = ShellCommand(remove, admin: true) }
        if p.warning == nil, remove != nil {
            p.warning = tr("It will be deleted for every user on this Mac.", "Se borrará para todos los usuarios de esta Mac.")
        }
        return p
    }
}
