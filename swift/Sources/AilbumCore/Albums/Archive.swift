import CryptoKit
import Foundation

public enum Archive {
    /// Test seam: replaces the real Trash. Throws to report a path it could not trash.
    nonisolated(unsafe) static var trasher: ((String) throws -> Void)?

    private static func ids(_ rows: [[String: SQLValue]], _ key: String) -> [Int] {
        rows.compactMap { if case .integer(let v)? = $0[key] { return Int(v) } else { return nil } }
    }

    private static func text(_ value: SQLValue?) -> String {
        if case .text(let s)? = value { return s }
        return ""
    }

    static func selectionHash(_ db: Database, _ albumId: Int) throws -> String {
        let list = ids(try db.query("SELECT image_id FROM album_photos WHERE album_id = ?", [.integer(albumId)]), "image_id").sorted()
        let digest = SHA256.hash(data: Data(list.map(String.init).joined(separator: ",").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func albumImageIds(_ db: Database, _ albumId: Int) throws -> Set<Int> {
        var out = Set(ids(try db.query("SELECT image_id FROM album_photos WHERE album_id = ?", [.integer(albumId)]), "image_id"))
        if let run = try db.query("SELECT run_id FROM albums WHERE id = ?", [.integer(albumId)]).first,
           case .text(let runId)? = run["run_id"], !runId.isEmpty {
            out.formUnion(ids(try db.query("SELECT image_id FROM photo_analysis WHERE run_id = ?", [.text(runId)]), "image_id"))
        }
        return out
    }

    private static func needsExport(_ db: Database, _ albumId: Int) throws -> Bool {
        if try db.query("SELECT 1 FROM layouts WHERE album_id = ?", [.integer(albumId)]).isEmpty { return false }
        let current = try selectionHash(db, albumId)
        return try db.query(
            "SELECT 1 FROM album_exports WHERE album_id = ? AND selection_hash = ? AND missing_json = '[]' LIMIT 1",
            [.integer(albumId), .text(current)]).isEmpty
    }

    private static func parent(_ database: String) -> String {
        let p = (database as NSString).deletingLastPathComponent
        return p.isEmpty ? "." : p
    }

    private static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    public static func prepare(database: String, albumId: Int) throws -> JSONValue {
        let db = try Database.open(path: database)
        let album = try Albums.get(db, albumId)
        if album["status"]?.stringValue == "archived" { throw AilbumError.invalid("Альбом уже в архиве") }
        if album["status"]?.stringValue == "draft" { _ = try Albums.setStatus(db, albumId, "ordered") }
        if try needsExport(db, albumId) {
            return ["album_id": .int(albumId), "needs_export": true, "trash": [], "blocked": []]
        }
        var paths: [Int: String] = [:]
        var sha: [Int: String] = [:]
        for imageId in try albumImageIds(db, albumId).sorted() {
            guard let row = try db.query("SELECT id, path, sha256, availability FROM images WHERE id = ?", [.integer(imageId)]).first,
                  text(row["availability"]) == "present" else { continue }
            paths[imageId] = text(row["path"])
            sha[imageId] = text(row["sha256"])
        }
        var draftTitles: [Int: String] = [:]
        for other in try Albums.list(db).arrayValue ?? [] {
            guard other["status"]?.stringValue == "draft", let otherId = other["id"]?.intValue else { continue }
            for imageId in try albumImageIds(db, otherId).intersection(paths.keys).sorted() where draftTitles[imageId] == nil {
                draftTitles[imageId] = other["title"]?.stringValue ?? ""
            }
        }
        let order = paths.keys.sorted()
        let result = try Proxies.build(database: database, imageIds: order)
        var errors: [Int: String] = [:]
        for f in result["failed"]?.arrayValue ?? [] {
            if let i = f["image_id"]?.intValue { errors[i] = f["error"]?.stringValue ?? "" }
        }
        let built = Set((result["built"]?.arrayValue ?? []).compactMap { $0.intValue })
        var trash: [JSONValue] = []
        var blocked: [JSONValue] = []
        for imageId in order {
            if let title = draftTitles[imageId] {
                blocked.append(["image_id": .int(imageId), "reason": .string("входит в черновик «\(title)»")])
            } else if !built.contains(imageId)
                        || !isFile(Proxies.photoProxy(database: database, sha256: sha[imageId] ?? "")) {
                let error = errors[imageId] ?? "превью не найдено"
                blocked.append(["image_id": .int(imageId), "reason": .string("не удалось построить превью: \(error)")])
            } else {
                trash.append(.string(paths[imageId] ?? ""))
            }
        }
        return ["album_id": .int(albumId), "needs_export": false, "trash": .array(trash), "blocked": .array(blocked)]
    }

    public static func complete(database: String, albumId: Int, trashed: [String]) throws -> JSONValue {
        let db = try Database.open(path: database)
        _ = try Albums.get(db, albumId)
        let wanted = Set(trashed)
        var archivedSha = Set<String>()
        var count = 0
        let imageIds = try albumImageIds(db, albumId).sorted()
        for imageId in imageIds {
            guard let row = try db.query("SELECT path, sha256, availability FROM images WHERE id = ?", [.integer(imageId)]).first,
                  text(row["availability"]) == "present" else { continue }
            let path = text(row["path"])
            if wanted.contains(path) && !FileManager.default.fileExists(atPath: path) {
                try db.execute("UPDATE images SET availability = 'archived' WHERE id = ?", [.integer(imageId)])
                archivedSha.insert(text(row["sha256"]))
                count += 1
            }
        }
        var remaining = 0
        for imageId in imageIds {
            let rows = try db.query("SELECT availability FROM images WHERE id = ?", [.integer(imageId)])
            if text(rows.first?["availability"]) == "present" { remaining += 1 }
        }
        var status = try Albums.get(db, albumId)["status"]?.stringValue ?? ""
        if remaining == 0 && status == "ordered" {
            status = try Albums.setStatus(db, albumId, "archived")["status"]?.stringValue ?? status
        }
        var removed = 0
        let cacheRoot = parent(database) + "/feature-cache"
        for sha in archivedSha.sorted() {
            if try !db.query("SELECT 1 FROM images WHERE sha256 = ? AND availability = 'present' LIMIT 1", [.text(sha)]).isEmpty { continue }
            let dirs = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot)) ?? []
            for dir in dirs {
                for ext in ["npz", "swcache"] {
                    let file = "\(cacheRoot)/\(dir)/\(sha).\(ext)"
                    if isFile(file), (try? FileManager.default.removeItem(atPath: file)) != nil { removed += 1 }
                }
            }
        }
        return ["archived": .int(count), "status": .string(status), "cache_removed": .int(removed)]
    }

    /// Returns only the paths the trasher reported as trashed; failures are skipped.
    public static func trashPaths(_ paths: [String]) -> [String] {
        var done: [String] = []
        for path in paths {
            do {
                if let trasher {
                    try trasher(path)
                } else {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
                done.append(path)
            } catch {
                continue
            }
        }
        return done
    }

    public static func confirmMissing(database: String, imageIds: [Int]) throws -> Int {
        if imageIds.isEmpty { return 0 }
        let db = try Database.open(path: database)
        let marks = Set(imageIds).sorted().map { _ in "?" }.joined(separator: ",")
        let args = Set(imageIds).sorted().map { SQLValue.integer($0) }
        var changed = 0
        try db.transaction {
            changed = try db.query(
                "SELECT COUNT(*) AS n FROM images WHERE availability = 'missing' AND id IN (\(marks))", args
            ).first.flatMap { if case .integer(let n)? = $0["n"] { return Int(n) } else { return nil } } ?? 0
            try db.execute("UPDATE images SET availability = 'archived' WHERE availability = 'missing' AND id IN (\(marks))", args)
        }
        return changed
    }
}
