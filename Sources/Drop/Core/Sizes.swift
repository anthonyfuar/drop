import Foundation

struct DiskInfo: Sendable {
    var size: Int64
    var lastAccess: Date?
    var lastModified: Date?
}

enum Sizes {
    private static let metadataNames: Set<String> = [
        "package.json", "METADATA", "RECORD", "INSTALLER", "top_level.txt", "WHEEL", "entry_points.txt", "PKG-INFO",
        "Info.plist", "extensions.json", "receipt.json", "uv-receipt.toml", "pyvenv.cfg", "direct_url.json", "REQUESTED",
        ".DS_Store", "Cargo.toml", "Project.toml", "Manifest.toml",
    ]

    static func measure(_ path: String) -> DiskInfo? {
        let fm = FileManager.default
        var target = path
        if let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            target = FS.resolve(path)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir) else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
                                         .contentAccessDateKey, .contentModificationDateKey, .nameKey]
        if !isDir.boolValue {
            let v = try? URL(fileURLWithPath: target).resourceValues(forKeys: keys)
            return DiskInfo(size: Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0),
                            lastAccess: v?.contentAccessDate, lastModified: v?.contentModificationDate)
        }
        var info = DiskInfo(size: 0)
        guard let en = fm.enumerator(at: URL(fileURLWithPath: target), includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return nil }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            info.size += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            let name = v.name ?? ""
            if !metadataNames.contains(name) && !url.path.contains(".dist-info/") && !url.path.contains(".egg-info/") {
                if let a = v.contentAccessDate, a > (info.lastAccess ?? .distantPast) { info.lastAccess = a }
            }
            if let m = v.contentModificationDate, m > (info.lastModified ?? .distantPast) { info.lastModified = m }
        }
        return info
    }

    static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        if bytes == 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = Date().timeIntervalSince(date) / 86_400
        if days < 1 { return tr("Today", "Hoy") }
        if days < 2 { return tr("Yesterday", "Ayer") }
        if days < 30 { return tr("\(Int(days)) days ago", "Hace \(Int(days)) días") }
        if days < 365 {
            let m = Int(days / 30)
            return m == 1 ? tr("1 month ago", "Hace 1 mes") : tr("\(m) months ago", "Hace \(m) meses")
        }
        let y = Int(days / 365)
        return y == 1 ? tr("1 year ago", "Hace 1 año") : tr("\(y) years ago", "Hace \(y) años")
    }
}
