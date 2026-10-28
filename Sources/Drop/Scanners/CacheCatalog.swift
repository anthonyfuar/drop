import Foundation

enum CleanSafety: Int, Sendable, Comparable {
    case safe
    case optional

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String { self == .safe ? tr("Safe", "Segura") : tr("Optional", "Opcional") }
}

struct CleanEntry: Sendable, Identifiable {
    var id: String { paths.first ?? label }
    let label: String
    let explanation: String
    let paths: [String]
    let command: String?
    let safety: CleanSafety

    var script: String {
        command ?? paths.map { "rm -rf \(q($0))" }.joined(separator: "; ")
    }
}

enum CacheCatalog {
    static func entries(_ env: ShellEnv) -> [CleanEntry] {
        let h = env.h
        let lib = h("Library/Caches")
        let tool = { (n: String) in env.which(n).map(q) }
        let xdgCache = env.vars["XDG_CACHE_HOME"] ?? h(".cache")
        var e: [CleanEntry] = []
        func add(_ label: String, _ why: String, _ paths: [String], _ cmd: String? = nil, _ safety: CleanSafety = .safe) {
            e.append(CleanEntry(label: label, explanation: why, paths: paths, command: cmd, safety: safety))
        }
        let redownload = tr("It downloads again automatically when needed.", "Se vuelve a descargar sola cuando hace falta.")
        let rebuild = tr("It’s rebuilt automatically the next time you build.", "Se vuelve a generar sola la próxima vez que compiles.")

        add(tr("npm — download cache", "npm — caché de descargas"), redownload, [env.vars["npm_config_cache"].map { $0.appendingPath("_cacache") } ?? h(".npm/_cacache")],
            tool("npm").map { "\($0) cache clean --force" })
        add(tr("npm — logs", "npm — registros (logs)"), tr("Old npm error logs.", "Registros de errores antiguos de npm."), [h(".npm/_logs")])
        add(tr("npx — temporary packages", "npx — paquetes temporales"), tr("npx downloads them again when you use them.", "npx los descarga de nuevo al usarlos."), [h(".npm/_npx")])
        add(tr("Yarn — cache", "Yarn — caché"), redownload, [lib.appendingPath("Yarn"), h(".yarn/berry/cache")])
        add(tr("pnpm — unused packages", "pnpm — paquetes sin usar"), tr("Only removes packages that no project uses.", "Solo quita paquetes que ningún proyecto usa."), [h("Library/pnpm/store")], tool("pnpm").map { "\($0) store prune" })
        add(tr("Bun — cache", "Bun — caché"), redownload, [h(".bun/install/cache")])
        add(tr("Deno — cache", "Deno — caché"), redownload, [env.vars["DENO_DIR"] ?? lib.appendingPath("deno")])
        add(tr("Corepack — cache", "Corepack — caché"), redownload, [xdgCache.appendingPath("node/corepack")])
        add(tr("node-gyp — Node headers", "node-gyp — cabeceras de Node"), redownload, [lib.appendingPath("node-gyp"), h(".node-gyp")])
        add(tr("Electron — downloads", "Electron — descargas"), redownload, [lib.appendingPath("electron"), lib.appendingPath("electron-builder")])
        add(tr("TypeScript — type cache", "TypeScript — caché de tipos"), redownload, [lib.appendingPath("typescript")])
        add(tr("Turborepo — cache", "Turborepo — caché"), rebuild, [lib.appendingPath("turbo")])
        add(tr("Nx — cache", "Nx — caché"), rebuild, [lib.appendingPath("nx")])
        add(tr("Playwright — test browsers", "Playwright — navegadores de prueba"), tr("You’ll need to run `npx playwright install` to use them again.", "Hará falta ejecutar `npx playwright install` para volver a usarlos."), [lib.appendingPath("ms-playwright")], nil, .optional)
        add(tr("Puppeteer — browsers", "Puppeteer — navegadores"), tr("Puppeteer will download them again when you reinstall it.", "Puppeteer los descargará de nuevo al reinstalar."), [xdgCache.appendingPath("puppeteer")], nil, .optional)
        add(tr("Cypress — test app", "Cypress — aplicación de pruebas"), tr("You’ll need to run `npx cypress install`.", "Hará falta `npx cypress install`."), [lib.appendingPath("Cypress")], nil, .optional)
        add(tr("Prisma — engines", "Prisma — motores"), tr("Prisma downloads them again when you run `prisma generate`.", "Prisma los descarga de nuevo al ejecutar `prisma generate`."), [xdgCache.appendingPath("prisma")])
        add(tr("Selenium — drivers", "Selenium — controladores"), redownload, [xdgCache.appendingPath("selenium")])
        add(tr("Jest / Metro — cache", "Jest / Metro — caché"), rebuild, [NSTemporaryDirectory().appendingPath("jest_dx"), NSTemporaryDirectory().appendingPath("metro-cache")])

        add(tr("pip — download cache", "pip — caché de descargas"), redownload, [env.vars["PIP_CACHE_DIR"] ?? lib.appendingPath("pip")])
        add(tr("uv — cache", "uv — caché"), redownload, [env.vars["UV_CACHE_DIR"] ?? xdgCache.appendingPath("uv")], tool("uv").map { "\($0) cache clean" })
        add(tr("Poetry — download cache", "Poetry — caché de descargas"), redownload, [lib.appendingPath("pypoetry/cache"), lib.appendingPath("pypoetry/artifacts")])
        add(tr("pipenv — cache", "pipenv — caché"), redownload, [lib.appendingPath("pipenv")])
        add(tr("pre-commit — hook environments", "pre-commit — entornos de hooks"), tr("They’re rebuilt automatically on your next commit.", "Se reconstruyen solos en el siguiente commit."), [xdgCache.appendingPath("pre-commit")])
        let hf = env.vars["HF_HOME"] ?? xdgCache.appendingPath("huggingface")
        add(tr("Hugging Face — models and datasets", "Hugging Face — modelos y datasets"), tr("Large AI models; they’ll download again if you use them. Your access token is left alone.", "Modelos de IA grandes; se volverán a descargar si los usas. Tu token de acceso no se toca."),
            [env.vars["HF_HUB_CACHE"] ?? hf.appendingPath("hub"), hf.appendingPath("datasets"), hf.appendingPath("xet")], nil, .optional)
        add(tr("PyTorch Hub — models", "PyTorch Hub — modelos"), tr("Downloaded models; they download again if you use them.", "Modelos descargados; se bajan de nuevo si los usas."), [xdgCache.appendingPath("torch")], nil, .optional)
        add(tr("Whisper — models", "Whisper — modelos"), tr("Speech-to-text models; they download again if you use them.", "Modelos de voz; se bajan de nuevo si los usas."), [xdgCache.appendingPath("whisper")], nil, .optional)
        add(tr("LM Studio — models", "LM Studio — modelos"), tr("Your downloaded local AI models.", "Tus modelos de IA locales descargados."), [h(".lmstudio/models"), h(".cache/lm-studio/models")], nil, .optional)
        for base in [h("miniconda3"), h("anaconda3"), h("miniforge3"), h("mambaforge"), h("micromamba"), "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base", "/opt/miniconda3", "/opt/anaconda3"] {
            if let cmd = tool("conda").map({ "\($0) clean --all --yes" }) ?? tool("mamba").map({ "\($0) clean --all --yes" }) {
                add(tr("Conda — downloaded packages", "Conda — paquetes descargados"), tr("Only removes installers and packages that no environment uses.", "Solo quita instaladores y paquetes que ningún entorno usa."), [base.appendingPath("pkgs")], cmd)
            }
        }

        let cargo = env.vars["CARGO_HOME"] ?? h(".cargo")
        add(tr("Cargo — downloaded packages", "Cargo — paquetes descargados"), redownload, [cargo.appendingPath("registry"), cargo.appendingPath("git")])
        let gopath = env.vars["GOPATH"]?.split(separator: ":").first.map(String.init) ?? h("go")
        add(tr("Go — downloaded modules", "Go — módulos descargados"), redownload, [gopath.appendingPath("pkg/mod")],
            tool("go").map { "\($0) clean -modcache" } ?? "chmod -R u+w \(q(gopath.appendingPath("pkg/mod"))); rm -rf \(q(gopath.appendingPath("pkg/mod")))")
        add(tr("Go — build cache", "Go — caché de compilación"), rebuild, [env.vars["GOCACHE"] ?? lib.appendingPath("go-build")], tool("go").map { "\($0) clean -cache" })
        add(tr("Gradle — cache", "Gradle — caché"), redownload, [h(".gradle/caches")])
        add(tr("Gradle — downloaded versions", "Gradle — versiones descargadas"), tr("Gradle downloads again whichever version each project needs.", "Gradle descarga de nuevo la versión que pida cada proyecto."), [h(".gradle/wrapper/dists")])
        add(tr("Maven — local repository", "Maven — repositorio local"), tr("It may contain libraries you installed yourself with `mvn install`.", "Puede contener librerías que instalaste tú con `mvn install`."), [h(".m2/repository")], nil, .optional)
        add(tr("Maven — downloaded versions", "Maven — versiones descargadas"), redownload, [h(".m2/wrapper")])
        add(tr("Gradle — daemon logs", "Gradle — registros del daemon"), tr("Old Gradle logs.", "Registros antiguos de Gradle."), [h(".gradle/daemon")])
        add(tr("NuGet (.NET) — packages", "NuGet (.NET) — paquetes"), redownload, [h(".nuget/packages"), h(".local/share/NuGet/http-cache")], tool("dotnet").map { "\($0) nuget locals all --clear" })
        add(tr("Rustup — downloads", "Rustup — descargas"), tr("Rust installers that were already used.", "Instaladores de Rust ya usados."), [env.vars["RUSTUP_HOME"].map { $0.appendingPath("downloads") } ?? h(".rustup/downloads"), h(".rustup/tmp")])
        add(tr("Go — editor analysis", "Go — análisis del editor"), rebuild, [lib.appendingPath("gopls"), lib.appendingPath("golangci-lint"), lib.appendingPath("staticcheck")])
        add(tr("nvm — downloads", "nvm — descargas"), tr("Node installers that were already used.", "Instaladores de Node ya usados."), [h(".nvm/.cache")])
        add(tr("pyenv / rbenv — downloads", "pyenv / rbenv — descargas"), tr("Python and Ruby installers that were already used.", "Instaladores de Python y Ruby ya usados."), [h(".pyenv/cache"), h(".rbenv/cache")])
        add(tr("asdf — downloads", "asdf — descargas"), tr("Installers that were already used.", "Instaladores ya usados."), [h(".asdf/downloads")])
        add(tr("mise — cache", "mise — caché"), redownload, [lib.appendingPath("mise")], tool("mise").map { "\($0) cache clear" })
        add(tr("SDKMAN! — temporary files", "SDKMAN! — archivos temporales"), tr("Installers that were already used.", "Instaladores ya usados."), [h(".sdkman/archives"), h(".sdkman/tmp")])
        add(tr("ghcup — cache", "ghcup — caché"), redownload, [h(".ghcup/cache"), h(".ghcup/tmp")])
        add(tr("Volta — cache", "Volta — caché"), redownload, [h(".volta/cache"), h(".volta/tmp")])
        add(tr("RubyGems / Bundler — cache", "RubyGems / Bundler — caché"), redownload, [h(".gem/specs"), h(".bundle/cache")])
        add(tr("opam — downloads", "opam — descargas"), redownload, [h(".opam/download-cache")])
        add(tr("Dune — cache", "Dune — caché"), rebuild, [xdgCache.appendingPath("dune")])
        add(tr("Elm / rebar3 / Nim — cache", "Elm / rebar3 / Nim — caché"), redownload, [h(".elm"), xdgCache.appendingPath("rebar3"), xdgCache.appendingPath("nim")])
        add(tr("Zig — cache", "Zig — caché"), rebuild, [xdgCache.appendingPath("zig"), lib.appendingPath("zig")])
        add(tr("R — package cache", "R — caché de paquetes"), redownload, [lib.appendingPath("org.R-project.R/R/pkgcache")])
        add(tr("Dart — analyzer", "Dart — analizador"), rebuild, [h(".dartServer")])
        add(tr("Lima — downloaded images", "Lima — imágenes descargadas"), redownload, [lib.appendingPath("lima")])
        add(tr("minikube — cache", "minikube — caché"), redownload, [h(".minikube/cache")])
        add(tr("Trivy — database", "Trivy — base de datos"), redownload, [lib.appendingPath("trivy")])
        add(tr("PlatformIO — cache", "PlatformIO — caché"), redownload, [h(".platformio/.cache")])
        add(tr("Arduino — downloads", "Arduino — descargas"), redownload, [h("Library/Arduino15/staging")])
        add(tr("ESP-IDF — downloads", "ESP-IDF — descargas"), redownload, [h(".espressif/dist")])
        add(tr("Unity — cache", "Unity — caché"), rebuild, [h("Library/Unity/cache")])
        add(tr("Bazelisk — downloaded versions", "Bazelisk — versiones descargadas"), redownload, [lib.appendingPath("bazelisk")])
        add(tr("Android — cache", "Android — caché"), redownload, [h(".android/cache")])
        add(tr("Kotlin/Native — dependencies", "Kotlin/Native — dependencias"), redownload, [h(".konan/cache"), h(".konan/dependencies")])
        add(tr("Ivy / sbt — cache", "Ivy / sbt — caché"), redownload, [h(".ivy2/cache"), h(".sbt/boot")])
        add(tr("Coursier — cache", "Coursier — caché"), redownload, [lib.appendingPath("Coursier/v1")])
        add(tr("Bazel — cache", "Bazel — caché"), rebuild, [lib.appendingPath("bazel"), "/private/var/tmp/_bazel_\(NSUserName())"])
        add("ccache", rebuild, [lib.appendingPath("ccache"), h(".ccache")])
        add("sccache", rebuild, [lib.appendingPath("Mozilla.sccache")])
        add(tr("Composer — cache", "Composer — caché"), redownload, [lib.appendingPath("composer"), h(".composer/cache")])
        add(tr("Dart / Flutter — downloaded packages", "Dart / Flutter — paquetes descargados"), tr("They download again with `flutter pub get`.", "Se descargan de nuevo con `flutter pub get`."), [h(".pub-cache/hosted")], nil, .optional)
        add(tr("Stack (Haskell) — indexes", "Stack (Haskell) — índices"), redownload, [h(".stack/pantry")])
        add(tr("Cabal — downloaded packages", "Cabal — paquetes descargados"), redownload, [h(".cabal/packages")])
        add(tr("Hex / Mix — cache", "Hex / Mix — caché"), redownload, [h(".hex/packages"), h(".hex/cache.ets")])
        add(tr("Julia — precompiled code", "Julia — código precompilado"), rebuild, [h(".julia/compiled")])
        add(tr("R renv — cache", "R renv — caché"), redownload, [lib.appendingPath("org.R-project.R/R/renv")])
        add(tr("cpanm — builds", "cpanm — compilaciones"), tr("Leftovers from Perl installs.", "Restos de instalaciones de Perl."), [h(".cpanm/work"), h(".cpanm/build.log")])
        add(tr("Terraform — provider cache", "Terraform — caché de proveedores"), redownload, [h(".terraform.d/plugin-cache")])
        add(tr("Helm — cache", "Helm — caché"), redownload, [lib.appendingPath("helm")])
        add(tr("kubectl — cache", "kubectl — caché"), redownload, [h(".kube/cache")])

        add("Xcode — DerivedData", rebuild, [h("Library/Developer/Xcode/DerivedData")])
        add(tr("Xcode — previews", "Xcode — vistas previas"), rebuild, [h("Library/Developer/Xcode/UserData/Previews")])
        add(tr("Xcode — documentation and cache", "Xcode — documentación y caché"), rebuild, [h("Library/Developer/Xcode/DocumentationCache"), lib.appendingPath("com.apple.dt.Xcode")])
        add(tr("Tool logs", "Registros de herramientas"), tr("Old logs from Homebrew, simulators, JetBrains and Android Studio.", "Registros antiguos de Homebrew, simuladores, JetBrains y Android Studio."),
            [h("Library/Logs/Homebrew"), h("Library/Logs/CoreSimulator"), h("Library/Logs/JetBrains"), h("Library/Logs/Google")])
        add(tr("Simulator — caches", "Simulador — cachés"), rebuild, [h("Library/Developer/CoreSimulator/Caches")])
        add(tr("Xcode — device support", "Xcode — soporte de dispositivos"), tr("It’s copied again when you connect an iPhone or iPad (takes a few minutes).", "Se vuelve a copiar al conectar un iPhone o iPad (tarda unos minutos)."),
            [h("Library/Developer/Xcode/iOS DeviceSupport"), h("Library/Developer/Xcode/watchOS DeviceSupport"), h("Library/Developer/Xcode/tvOS DeviceSupport")], nil, .optional)
        add(tr("Swift Package Manager — cache", "Swift Package Manager — caché"), redownload, [lib.appendingPath("org.swift.swiftpm")])
        add(tr("CocoaPods — cache", "CocoaPods — caché"), redownload, [lib.appendingPath("CocoaPods")])
        add(tr("Carthage — cache", "Carthage — caché"), redownload, [lib.appendingPath("org.carthage.CarthageKit")])
        add(tr("JetBrains — indexes and caches", "JetBrains — índices y cachés"), tr("JetBrains IDEs re-index your projects when you open them.", "Los IDE de JetBrains vuelven a indexar al abrirlos."), [lib.appendingPath("JetBrains")])
        add(tr("Android Studio — caches", "Android Studio — cachés"), tr("They’re recreated when you open Android Studio.", "Se regeneran al abrir Android Studio."), FS.children(lib.appendingPath("Google")).filter { $0.hasPrefix("AndroidStudio") }.map { lib.appendingPath("Google/\($0)") })
        add(tr("CocoaPods — specs repository", "CocoaPods — repositorio de specs"), tr("An old copy of the CocoaPods index; CocoaPods now uses its CDN instead.", "Copia antigua del índice de CocoaPods; hoy se usa la CDN."), [h(".cocoapods/repos/trunk")])
        for (app, name) in [("Code", "VS Code"), ("Cursor", "Cursor"), ("Windsurf", "Windsurf")] {
            let base = h("Library/Application Support/\(app)")
            add(tr("\(name) — downloaded extensions", "\(name) — extensiones descargadas"), tr("Installers for extensions that are already installed.", "Instaladores de extensiones ya instaladas."), [base.appendingPath("CachedExtensionVSIXs")])
            add(tr("\(name) — cache", "\(name) — caché"), tr("It’s recreated when you open the editor.", "Se regenera al abrir el editor."), [base.appendingPath("Cache"), base.appendingPath("CachedData"), base.appendingPath("GPUCache"), base.appendingPath("Code Cache")])
        }
        add(tr("Claude Code — cache", "Claude Code — caché"), tr("Claude Code logs and cache.", "Registros y caché de Claude Code."), [lib.appendingPath("claude-cli-nodejs")])
        add(tr("Homebrew — downloads", "Homebrew — descargas"), tr("Installers that were already used. Homebrew downloads them again if it needs them.", "Instaladores ya usados. Homebrew los descarga de nuevo si los necesita."), [env.vars["HOMEBREW_CACHE"] ?? lib.appendingPath("Homebrew")],
            tool("brew").map { "\($0) cleanup --prune=all -s; rm -rf \(q(lib.appendingPath("Homebrew/downloads")))/* \(q(lib.appendingPath("Homebrew/Cask")))/*" })

        var result: [CleanEntry] = []
        var seenCommands = Set<String>()
        for entry in e {
            let existing = entry.paths.filter { FS.exists($0) && (!FS.isDir($0) || !FS.children($0).isEmpty) }
            guard !existing.isEmpty else { continue }
            let cmd = entry.command ?? existing.map { "rm -rf \(q($0))" }.joined(separator: "; ")
            if entry.command != nil && !seenCommands.insert(cmd).inserted { continue }
            result.append(CleanEntry(label: entry.label, explanation: entry.explanation, paths: existing, command: cmd, safety: entry.safety))
        }
        return result
    }
}

struct CacheScanner: Scanner {
    func scan(_ env: ShellEnv) async -> [Package] {
        CacheCatalog.entries(env).flatMap { entry in
            entry.paths.map { path in
                var p = Package(source: Src.cache, name: entry.paths.count > 1 ? "\(entry.label) (\(path.lastPathComponent))" : entry.label, version: "—", key: path)
                p.path = path
                p.summary = entry.explanation
                p.details.append((tr("Safety", "Seguridad"), entry.safety == .safe ? tr("Safe to delete", "Segura de borrar") : tr("Optional: you’ll need to download it again", "Opcional: requiere volver a descargar")))
                if entry.safety == .optional { p.warning = entry.explanation }
                let script = entry.paths.count == 1 ? entry.script : "rm -rf \(q(path))"
                p.commands = [.remove: ShellCommand(script, admin: !FS.isWritable(path.deletingLastPathComponent))]
                return p
            }
        }
    }
}
