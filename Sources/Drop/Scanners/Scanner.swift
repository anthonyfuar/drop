import Foundation

protocol Scanner: Sendable {
    func scan(_ env: ShellEnv) async -> [Package]
    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String]
}

extension Scanner {
    func latestVersions(_ env: ShellEnv, _ packages: [Package]) async -> [String: String] { [:] }
}

enum Registry {
    static let all: [any Scanner] = [
        HomebrewScanner(), MacPortsScanner(), NixScanner(), PkgReceiptScanner(),
        NpmScanner(), NpxCacheScanner(), PnpmScanner(), YarnScanner(), BunScanner(), DenoScanner(), VoltaScanner(),
        PipScanner(), PipxScanner(), UvToolScanner(), CondaScanner(),
        GemScanner(), CargoScanner(), GoBinScanner(), ComposerScanner(), PeclScanner(),
        DotnetToolScanner(), DartPubScanner(), LuaRocksScanner(), OpamScanner(), CabalScanner(), RPackageScanner(), JuliaScanner(), MintScanner(),
        EditorExtensionScanner(), GhExtensionScanner(), OllamaScanner(), DockerScanner(), HelmPluginScanner(), KrewScanner(),
        RuntimeVersionsScanner(), ExtraVersionsScanner(), ActiveRuntimesScanner(),
        PyEnvScanner(), VMScanner(), SDKScanner(),
        CacheScanner(), LooseBinaryScanner(), ProjectScanner(),
    ]
}

enum Src {
    static let brew = SourceInfo(id: "brew", en: "Homebrew", es: "Homebrew", symbol: "mug", group: .system)
    static let cask = SourceInfo(id: "cask", en: "Homebrew Casks", es: "Homebrew Casks", symbol: "macwindow", group: .system)
    static let tap = SourceInfo(id: "tap", en: "Homebrew Taps", es: "Homebrew Taps", symbol: "link", group: .system, removeEn: "Remove tap", removeEs: "Quitar tap")
    static let macports = SourceInfo(id: "macports", en: "MacPorts", es: "MacPorts", symbol: "shippingbox.circle", group: .system)
    static let nix = SourceInfo(id: "nix", en: "Nix", es: "Nix", symbol: "snowflake", group: .system)
    static let pkg = SourceInfo(id: "pkg", en: "Installer packages (.pkg)", es: "Instaladores .pkg", symbol: "shippingbox", group: .system)

    static let npm = SourceInfo(id: "npm", en: "npm (global)", es: "npm (global)", symbol: "n.square", group: .javascript)
    static let npx = SourceInfo(id: "npx", en: "npx cache", es: "Caché de npx", symbol: "bolt.square", group: .javascript, removeEn: "Remove", removeEs: "Eliminar")
    static let pnpm = SourceInfo(id: "pnpm", en: "pnpm (global)", es: "pnpm (global)", symbol: "p.square", group: .javascript)
    static let yarn = SourceInfo(id: "yarn", en: "Yarn (global)", es: "Yarn (global)", symbol: "y.square", group: .javascript)
    static let bun = SourceInfo(id: "bun", en: "Bun (global)", es: "Bun (global)", symbol: "b.square", group: .javascript)
    static let deno = SourceInfo(id: "deno", en: "Deno (installed)", es: "Deno (instalados)", symbol: "d.square", group: .javascript)
    static let volta = SourceInfo(id: "volta", en: "Volta", es: "Volta", symbol: "bolt.horizontal", group: .javascript)

    static let pip = SourceInfo(id: "pip", en: "pip", es: "pip", symbol: "p.circle", group: .python)
    static let pipx = SourceInfo(id: "pipx", en: "pipx", es: "pipx", symbol: "x.circle", group: .python)
    static let uvTool = SourceInfo(id: "uvtool", en: "uv tools", es: "uv tools", symbol: "u.circle", group: .python)
    static let conda = SourceInfo(id: "conda", en: "Conda (environments)", es: "Conda (entornos)", symbol: "c.circle", group: .python, removeEn: "Remove environment", removeEs: "Eliminar entorno")

    static let gem = SourceInfo(id: "gem", en: "RubyGems", es: "RubyGems", symbol: "diamond", group: .ruby)
    static let cargo = SourceInfo(id: "cargo", en: "Cargo", es: "Cargo", symbol: "shippingbox.and.arrow.backward", group: .rust)
    static let goBin = SourceInfo(id: "gobin", en: "go install", es: "go install", symbol: "g.circle", group: .go, removeEn: "Remove", removeEs: "Eliminar")
    static let composer = SourceInfo(id: "composer", en: "Composer (global)", es: "Composer (global)", symbol: "music.note.list", group: .php)
    static let pecl = SourceInfo(id: "pecl", en: "PECL", es: "PECL", symbol: "puzzlepiece.extension", group: .php)

    static let dotnetTool = SourceInfo(id: "dotnettool", en: ".NET tools", es: ".NET tools", symbol: "number.square", group: .otherLanguages)
    static let dartPub = SourceInfo(id: "dartpub", en: "Dart pub global", es: "Dart pub global", symbol: "arrowtriangle.right.square", group: .otherLanguages)
    static let luarocks = SourceInfo(id: "luarocks", en: "LuaRocks", es: "LuaRocks", symbol: "moon", group: .otherLanguages)
    static let opam = SourceInfo(id: "opam", en: "opam (OCaml)", es: "opam (OCaml)", symbol: "o.circle", group: .otherLanguages)
    static let cabal = SourceInfo(id: "cabal", en: "Cabal (Haskell)", es: "Cabal (Haskell)", symbol: "function", group: .otherLanguages, removeEn: "Remove", removeEs: "Eliminar")
    static let rPkg = SourceInfo(id: "rpkg", en: "R packages", es: "Paquetes de R", symbol: "r.circle", group: .otherLanguages)
    static let julia = SourceInfo(id: "julia", en: "Julia", es: "Julia", symbol: "j.circle", group: .otherLanguages)
    static let mint = SourceInfo(id: "mint", en: "Mint (Swift)", es: "Mint (Swift)", symbol: "swift", group: .otherLanguages)

    static let editorExt = SourceInfo(id: "editorext", en: "Editor extensions", es: "Extensiones de editores", symbol: "puzzlepiece", group: .tools)
    static let ghExt = SourceInfo(id: "ghext", en: "GitHub CLI extensions", es: "Extensiones de gh", symbol: "terminal", group: .tools)
    static let ollama = SourceInfo(id: "ollama", en: "Ollama models", es: "Modelos de Ollama", symbol: "brain", group: .tools, removeEn: "Remove", removeEs: "Eliminar")
    static let docker = SourceInfo(id: "docker", en: "Docker images", es: "Imágenes Docker", symbol: "cube.transparent", group: .tools, removeEn: "Remove", removeEs: "Eliminar")
    static let helm = SourceInfo(id: "helm", en: "Helm plugins", es: "Plugins de Helm", symbol: "steeringwheel", group: .tools)
    static let krew = SourceInfo(id: "krew", en: "kubectl plugins", es: "Plugins de kubectl", symbol: "k.circle", group: .tools)

    static let vms = SourceInfo(id: "vms", en: "Virtual machines & emulators", es: "Máquinas virtuales y emuladores", symbol: "desktopcomputer", group: .tools, removeEn: "Remove", removeEs: "Eliminar")
    static let sdk = SourceInfo(id: "sdk", en: "SDKs & kits", es: "SDKs y kits", symbol: "hammer", group: .tools)
    static let pyenvs = SourceInfo(id: "pyenvs", en: "Python environments", es: "Entornos de Python", symbol: "shippingbox.circle", group: .python, removeEn: "Remove", removeEs: "Eliminar")

    static let versions = SourceInfo(id: "versions", en: "Language versions", es: "Versiones de lenguajes", symbol: "square.stack.3d.up", group: .runtimes, removeEn: "Remove", removeEs: "Eliminar")
    static let active = SourceInfo(id: "active", en: "Languages in use", es: "Lenguajes en uso", symbol: "cpu", group: .runtimes)

    static let projects = SourceInfo(id: "projects", en: "Project dependencies", es: "Dependencias de proyectos", symbol: "folder.badge.gearshape", group: .projects, removeEn: "Delete", removeEs: "Borrar")

    static let cache = SourceInfo(id: "cache", en: "Caches", es: "Cachés", symbol: "archivebox", group: .caches, removeEn: "Empty", removeEs: "Vaciar")
    static let loose = SourceInfo(id: "loose", en: "Loose commands", es: "Comandos sueltos", symbol: "doc.badge.gearshape", group: .caches, removeEn: "Remove", removeEs: "Eliminar")
}
