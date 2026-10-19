import Foundation

/// Metadata written to <scan folder>/meta.json once a scan is finalized.
struct ScanMeta: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var createdAt: Date
    var durationSeconds: Double
    var deviceModel: String
    var appVersion: String

    var meshAnchorCount: Int
    var meshVertexCount: Int
    var meshFaceCount: Int
    var pointCount: Int
    var keyframeCount: Int

    var voxelSizeMeters: Float
    var minConfidence: Int
    var maxDepthMeters: Float

    var imageWidth: Int
    var imageHeight: Int
    var depthWidth: Int
    var depthHeight: Int

    /// Documentation for whoever consumes the bundle.
    var coordinateSystem: String
    var notes: String

    var folder: URL { ScanStore.folder(for: id) }
}

enum ScanStore {
    static let appVersion = "0.1.0"

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    static func makeID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Scan_" + f.string(from: Date())
    }

    /// Creates the folder layout for a new scan.
    static func createScanFolder(id: String) throws -> URL {
        let fm = FileManager.default
        let folder = folder(for: id)
        try fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)
        return folder
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func saveMeta(_ meta: ScanMeta) throws {
        let data = try encoder.encode(meta)
        try data.write(to: folder(for: meta.id).appendingPathComponent("meta.json"), options: .atomic)
    }

    static func loadMeta(id: String) -> ScanMeta? {
        guard let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("meta.json")) else { return nil }
        return try? decoder.decode(ScanMeta.self, from: data)
    }

    /// All finalized scans, newest first. Folders without meta.json (aborted scans) are ignored.
    static func listScans() -> [ScanMeta] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items
            .compactMap { url -> ScanMeta? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return loadMeta(id: url.lastPathComponent)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        try? FileManager.default.removeItem(at: zipURL(for: id))
    }

    /// Removes folders that never got a meta.json (recording discarded or app killed mid-scan).
    static func purgeIncomplete() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in items where loadMeta(id: url.lastPathComponent) == nil {
            try? fm.removeItem(at: url)
        }
    }

    static func folderSize(id: String) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder(for: id), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func zipURL(for id: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("\(id).zip")
    }

    /// Zips a scan folder using Foundation's file coordinator (no third-party dependency).
    static func makeZip(id: String) throws -> URL {
        let src = folder(for: id)
        let dest = zipURL(for: id)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }

        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: .forUploading, error: &coordError) { tmpZip in
            do { try fm.copyItem(at: tmpZip, to: dest) } catch { copyError = error }
        }
        if let e = coordError { throw e }
        if let e = copyError { throw e }
        return dest
    }
}
