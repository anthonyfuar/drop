import Foundation
enum SourceGroup: Int, CaseIterable, Sendable, Comparable {
    case system, javascript, python, ruby, rust, go, php, otherLanguages, tools, projects, runtimes, caches, loose

    var title: String {
        switch self {
        case .system: tr("Apps & System", "Apps y sistema")
        case .javascript: "JavaScript"
        case .python: "Python"
        case .ruby: "Ruby"
        case .rust: "Rust"
        case .go: "Go"
        case .php: "PHP"
        case .otherLanguages: tr("Other Languages", "Otros lenguajes")
        case .tools: tr("Tools & Virtual Machines", "Herramientas y máquinas virtuales")
        case .projects: tr("Projects", "Proyectos")
        case .runtimes: tr("Language Versions", "Versiones de lenguajes")
        case .caches: tr("Caches & Leftovers", "Cachés y restos")
        case .loose: tr("Loose Commands", "Comandos sueltos")
        }
    }

    var symbol: String {
        switch self {
        case .system: "macwindow"
        case .javascript: "curlybraces"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .ruby: "diamond"
        case .rust: "gearshape.2"
        case .go: "hare"
        case .php: "server.rack"
        case .otherLanguages: "ellipsis.curlybraces"
        case .tools: "wrench.and.screwdriver"
        case .projects: "folder"
        case .runtimes: "square.stack.3d.up"
        case .caches: "archivebox"
        case .loose: "terminal"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
struct SourceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let en: String
    let es: String
    let symbol: String
    let group: SourceGroup
    var removeEn = "Uninstall"
    var removeEs = "Desinstalar"

    var name: String { tr(en, es) }
    var removeVerb: String { tr(removeEn, removeEs) }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum PackageAction: String, CaseIterable, Sendable, Hashable {
    case update, repair, remove

    var symbol: String {
        switch self {
        case .update: "arrow.up.circle"
        case .repair: "wrench.and.screwdriver"
        case .remove: "trash"
        }
    }

    func title(for source: SourceInfo?) -> String {
        switch self {
        case .update: tr("Update", "Actualizar")
        case .repair: tr("Repair", "Reparar")
        case .remove: source?.removeVerb ?? tr("Uninstall", "Desinstalar")
        }
    }
}
struct ShellCommand: Hashable, Sendable {
    var script: String
    var needsAdmin = false

    init(_ script: String, admin: Bool = false) {
        self.script = script
        self.needsAdmin = admin
    }
}

struct Package: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var version: String
    var latest: String?
    var source: SourceInfo
    var summary: String?
    var path: String?
    var context: String?
    var isDependency = false
    var warning: String?
    var homepage: String?
    var knownSize: Int64?
    var details: [(String, String)] = []
    var commands: [PackageAction: ShellCommand] = [:]

    init(source: SourceInfo, name: String, version: String, context: String? = nil, key: String? = nil) {
        self.source = source
        self.name = name
        self.version = version
        self.context = context
        self.id = "\(source.id)|\(context ?? "")|\(key ?? name)"
    }

    var isOutdated: Bool {
        guard let latest, !latest.isEmpty else { return false }
        return Version.normalize(latest) != Version.normalize(version)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.version == b.version && a.latest == b.latest && a.path == b.path && a.isDependency == b.isDependency
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Version {
    static func normalize(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        return s
    }
}

func q(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
    var lastPathComponent: String { (self as NSString).lastPathComponent }
    var deletingLastPathComponent: String { (self as NSString).deletingLastPathComponent }
    func appendingPath(_ c: String) -> String { (self as NSString).appendingPathComponent(c) }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] { split(whereSeparator: \.isNewline).map(String.init) }
}

enum FS {
    static let fm = FileManager.default

    static func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func children(_ p: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    static func resolve(_ p: String) -> String {
        (p as NSString).resolvingSymlinksInPath
    }

    static func json(_ p: String) -> Any? {
        guard let d = fm.contents(atPath: p) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    static func isWritable(_ p: String) -> Bool { fm.isWritableFile(atPath: p) }
}

extension Substring {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Data {
    var json: Any? { try? JSONSerialization.jsonObject(with: self) }
}

func parseJSON(_ s: String) -> Any? {
    guard let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    return Data(s[start...].utf8).json
}
