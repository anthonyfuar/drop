import Foundation

struct ProjectScanner: Scanner {
    struct Pattern: Sendable {
        let dir: String
        let markers: [String]
        let kindEn: String
        let kindEs: String
        let recreateEn: String
        let recreateEs: String
        let isPythonEnv: Bool

        init(dir: String, markers: [String], kind en: String, _ es: String, recreate: String, _ recreateEs: String? = nil, isPythonEnv: Bool = false) {
            self.dir = dir
            self.markers = markers
            self.kindEn = en
            self.kindEs = es
            self.recreateEn = recreate
            self.recreateEs = recreateEs ?? recreate
            self.isPythonEnv = isPythonEnv
        }

        var kind: String { tr(kindEn, kindEs) }
        var recreate: String { tr(recreateEn, recreateEs) }
    }

    static let patterns: [Pattern] = [
        Pattern(dir: "node_modules", markers: [], kind: "node_modules", "node_modules", recreate: "npm install / pnpm install / yarn"),
        Pattern(dir: ".venv", markers: [], kind: "Python environment", "Entorno de Python", recreate: "pip/uv/poetry install", isPythonEnv: true),
        Pattern(dir: "venv", markers: [], kind: "Python environment", "Entorno de Python", recreate: "pip install -r requirements.txt", isPythonEnv: true),
        Pattern(dir: "env", markers: [], kind: "Python environment", "Entorno de Python", recreate: "pip install -r requirements.txt", isPythonEnv: true),
        Pattern(dir: ".tox", markers: [], kind: "tox environments", "Entornos de tox", recreate: "tox"),
        Pattern(dir: ".nox", markers: [], kind: "nox environments", "Entornos de nox", recreate: "nox"),
        Pattern(dir: "target", markers: ["Cargo.toml"], kind: "Rust build", "Compilación de Rust", recreate: "cargo build"),
        Pattern(dir: "target", markers: ["pom.xml"], kind: "Maven build", "Compilación de Maven", recreate: "mvn package"),
        Pattern(dir: ".next", markers: ["package.json"], kind: "Next.js cache", "Caché de Next.js", recreate: "next build / next dev"),
        Pattern(dir: ".nuxt", markers: ["package.json"], kind: "Nuxt cache", "Caché de Nuxt", recreate: "nuxt dev"),
        Pattern(dir: ".svelte-kit", markers: ["package.json"], kind: "SvelteKit cache", "Caché de SvelteKit", recreate: "vite dev"),
        Pattern(dir: ".turbo", markers: ["package.json"], kind: "Turborepo cache", "Caché de Turborepo", recreate: "turbo run"),
        Pattern(dir: ".parcel-cache", markers: ["package.json"], kind: "Parcel cache", "Caché de Parcel", recreate: "parcel"),
        Pattern(dir: ".angular", markers: ["angular.json"], kind: "Angular cache", "Caché de Angular", recreate: "ng build"),
        Pattern(dir: ".expo", markers: ["package.json"], kind: "Expo cache", "Caché de Expo", recreate: "expo start"),
        Pattern(dir: "Pods", markers: ["Podfile"], kind: "CocoaPods", "CocoaPods", recreate: "pod install"),
        Pattern(dir: ".build", markers: ["Package.swift"], kind: "Swift build", "Compilación de Swift", recreate: "swift build"),
        Pattern(dir: ".dart_tool", markers: ["pubspec.yaml"], kind: "Dart tools", "Herramientas de Dart", recreate: "flutter pub get"),
        Pattern(dir: "build", markers: ["pubspec.yaml"], kind: "Flutter build", "Compilación de Flutter", recreate: "flutter build"),
        Pattern(dir: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], kind: "Gradle cache", "Caché de Gradle", recreate: "gradle build"),
        Pattern(dir: "build", markers: ["build.gradle", "build.gradle.kts"], kind: "Gradle build", "Compilación de Gradle", recreate: "gradle build"),
        Pattern(dir: "vendor", markers: ["composer.json"], kind: "PHP dependencies", "Dependencias de PHP", recreate: "composer install"),
        Pattern(dir: "vendor", markers: ["Gemfile"], kind: "Ruby dependencies", "Dependencias de Ruby", recreate: "bundle install"),
        Pattern(dir: ".zig-cache", markers: ["build.zig"], kind: "Zig cache", "Caché de Zig", recreate: "zig build"),
        Pattern(dir: "zig-out", markers: ["build.zig"], kind: "Zig build", "Compilación de Zig", recreate: "zig build"),
        Pattern(dir: "_build", markers: ["mix.exs"], kind: "Elixir build", "Compilación de Elixir", recreate: "mix compile"),
        Pattern(dir: "deps", markers: ["mix.exs"], kind: "Elixir dependencies", "Dependencias de Elixir", recreate: "mix deps.get"),
        Pattern(dir: ".stack-work", markers: ["stack.yaml"], kind: "Haskell build", "Compilación de Haskell", recreate: "stack build"),
        Pattern(dir: "dist-newstyle", markers: [], kind: "Cabal build", "Compilación de Cabal", recreate: "cabal build"),
        Pattern(dir: "DerivedData", markers: [], kind: "Xcode build", "Compilación de Xcode", recreate: "build in Xcode", "compilar en Xcode"),
    ]

    static let skipRoots: Set<String> = ["Library", "Applications", "Music", "Movies", "Pictures", "Public", ".Trash"]
    static let privacyRoots: Set<String> = ["Desktop", "Documents", "Downloads"]
    static let allowedHidden: Set<String> = Set(patterns.map(\.dir).filter { $0.hasPrefix(".") })
    static let neverDescend: Set<String> = [".git", ".svn", ".hg", "node_modules", "Pods", "DerivedData", "__pycache__", ".venv", "venv",
                                            "target", ".build", "vendor", "site-packages", ".gradle", ".next", "build", "dist"]

    var deep = false

    func scan(_ env: ShellEnv) async -> [Package] {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(deep ? 90 : 25)
        let maxDepth = deep ? 14 : 7
        let maxResults = deep ? 10000 : 3000
        var found: [(path: String, project: String, pattern: Pattern)] = []
        var queue: [(String, Int)] = [(env.home, 0)]
        if deep {
            for extra in ["/Users/Shared", "/opt"] where FS.isDir(extra) { queue.append((extra, 0)) }
        }
        let byDir = Dictionary(grouping: Self.patterns, by: \.dir)

        while !queue.isEmpty, Date() < deadline, found.count < maxResults {
            let (dir, depth) = queue.removeFirst()
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let names = Set(entries)
            for name in entries {
                let full = dir.appendingPath(name)
                guard FS.isDir(full), (try? fm.destinationOfSymbolicLink(atPath: full)) == nil else { continue }
                if depth == 0 && dir == env.home && (Self.skipRoots.contains(name) || (!deep && Self.privacyRoots.contains(name))) { continue }
                if full == "/opt/homebrew" { continue }
                if let candidates = byDir[name] {
                    if let p = candidates.first(where: { pat in
                        if pat.isPythonEnv { return FS.exists(full.appendingPath("pyvenv.cfg")) }
                        return pat.markers.isEmpty || pat.markers.contains(where: names.contains)
                    }) {
                        found.append((full, dir, p))
                        continue
                    }
                }
                if name.hasPrefix(".") && !Self.allowedHidden.contains(name) { continue }
                if Self.neverDescend.contains(name) || name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") { continue }
                if depth < maxDepth { queue.append((full, depth + 1)) }
            }
        }

        return found.map { item in
            let projectName = item.project.lastPathComponent
            var p = Package(source: Src.projects, name: projectName, version: item.pattern.kind, context: item.project.deletingLastPathComponent.abbreviatingHome, key: item.path)
            p.path = item.path
            p.summary = tr("\(item.pattern.kind) for the “\(projectName)” project. You can recreate it with `\(item.pattern.recreate)`.",
                           "\(item.pattern.kind) del proyecto “\(projectName)”. Se recrea con `\(item.pattern.recreate)`.")
            p.details.append((tr("Project", "Proyecto"), item.project))
            p.details.append((tr("Recreate with", "Se recrea con"), item.pattern.recreate))
            p.commands[.remove] = ShellCommand("rm -rf \(q(item.path))")
            return p
        }
    }
}
