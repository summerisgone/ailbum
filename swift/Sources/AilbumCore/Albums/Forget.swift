import Foundation

/// Port of src/ailbum/forget.py.
public enum Forget {
    private static func marks(_ ids: [Int]) -> String { ids.map { _ in "?" }.joined(separator: ", ") }
    private static func args(_ ids: [Int]) -> [SQLValue] { ids.map { .integer($0) } }
    private static func int(_ v: SQLValue?) -> Int? {
        if case .integer(let i)? = v { return Int(i) }
        return nil
    }
    private static func root(_ database: String) -> String {
        (database as NSString).deletingLastPathComponent + "/proxies"
    }

    private static func scope(_ db: Database, albumId: Int?, source: String?) throws -> [Int] {
        if (albumId == nil) == (source == nil) {
            throw AilbumError.invalid("Укажите ровно одно: альбом или источник")
        }
        let rows: [[String: SQLValue]]
        if let albumId {
            let album = try Albums.get(db, albumId)
            let run: SQLValue = album["run_id"]?.stringValue.map { .text($0) } ?? .null
            rows = try db.query(
                """
                SELECT image_id FROM album_photos WHERE album_id = ?
                UNION
                SELECT image_id FROM photo_analysis WHERE run_id = ?
                """, [.integer(albumId), run])
        } else {
            rows = try db.query("SELECT id FROM images WHERE source_root = ?", [.text(source ?? "")])
        }
        return rows.compactMap { int($0.values.first) }.sorted()
    }

    private static func proxyFiles(_ db: Database, database: String, ids: [Int], faceIds: [Int]) throws -> [String] {
        let base = root(database)
        let m = marks(ids)
        let shas = Set(try db.query("SELECT sha256 FROM images WHERE id IN (\(m))", args(ids)).compactMap {
            row -> String? in
            if case .text(let s)? = row["sha256"] { return s }
            return nil
        })
        var files: [String] = []
        for sha in shas.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let shared = try db.query(
                "SELECT 1 FROM images WHERE sha256 = ? AND id NOT IN (\(m)) LIMIT 1", [.text(sha)] + args(ids))
            if shared.isEmpty { files.append("\(base)/photos/\(sha).jpg") }
        }
        files += faceIds.map { "\(base)/faces/\($0).jpg" }
        return files.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func buildPlan(_ db: Database, database: String, ids: [Int], albumId: Int?) throws -> JSONValue {
        var plan: [String: JSONValue] = [
            "images": .int(ids.count), "faces": 0, "people_affected": [], "people_removed": [],
            "albums_affected": [], "layouts_placements": 0, "events": 0, "proxies": 0,
        ]
        if ids.isEmpty { return .object(plan) }
        let m = marks(ids)
        let faces = try db.query("SELECT id, person_id FROM faces WHERE image_id IN (\(m))", args(ids))
        let faceIds = Set(faces.compactMap { int($0["id"]) })
        let people = Set(faces.compactMap { int($0["person_id"]) }).sorted()
        var removed: [Int] = []
        for person in people {
            let remaining = try db.query("SELECT id FROM faces WHERE person_id = ?", [.integer(person)])
            if remaining.allSatisfy({ faceIds.contains(int($0["id"]) ?? -1) }) { removed.append(person) }
        }
        let affected = try db.query(
            """
            SELECT DISTINCT a.id, a.title FROM albums AS a
            LEFT JOIN album_photos AS ap ON ap.album_id = a.id
            WHERE ap.image_id IN (\(m)) OR a.id = ?
            ORDER BY a.id
            """, args(ids) + [albumId.map { .integer($0) } ?? .null])
        func count(_ table: String) throws -> Int {
            int(try db.query("SELECT COUNT(*) AS n FROM \(table) WHERE image_id IN (\(m))", args(ids)).first?["n"]) ?? 0
        }
        plan["faces"] = .int(faceIds.count)
        plan["people_affected"] = .array(people.map { .int($0) })
        plan["people_removed"] = .array(removed.map { .int($0) })
        plan["albums_affected"] = .array(affected.map { JSONValue.row($0) })
        plan["layouts_placements"] = .int(try count("layout_placements"))
        plan["events"] = .int(try count("selection_events"))
        plan["proxies"] = .int(try proxyFiles(db, database: database, ids: ids, faceIds: faceIds.sorted()).count)
        return .object(plan)
    }

    public static func plan(database: String, albumId: Int?, source: String?) throws -> JSONValue {
        let db = try Database.open(path: database)
        let ids = try scope(db, albumId: albumId, source: source)
        return try buildPlan(db, database: database, ids: ids, albumId: albumId)
    }

    public static func forget(database: String, albumId: Int?, source: String?) throws -> JSONValue {
        let db = try Database.open(path: database)
        var plan: JSONValue = .null
        var files: [String] = []
        try db.transaction {
            let ids = try scope(db, albumId: albumId, source: source)
            plan = try buildPlan(db, database: database, ids: ids, albumId: albumId)
            if !ids.isEmpty {
                let m = marks(ids)
                let faces = try db.query("SELECT id, person_id FROM faces WHERE image_id IN (\(m))", args(ids))
                files = try proxyFiles(db, database: database, ids: ids, faceIds: faces.compactMap { int($0["id"]) })
                let people = Set(faces.compactMap { int($0["person_id"]) })
                try db.execute("DELETE FROM layout_placements WHERE image_id IN (\(m))", args(ids))
                for table in ["selection_events", "album_photos", "faces", "photo_analysis", "image_object_scans"] {
                    try db.execute("DELETE FROM \(table) WHERE image_id IN (\(m))", args(ids))
                }
                try db.execute("DELETE FROM images WHERE id IN (\(m))", args(ids))
                for person in people.sorted() {
                    let left = try db.query("SELECT 1 FROM faces WHERE person_id = ? LIMIT 1", [.integer(person)])
                    if left.isEmpty {
                        try db.execute("DELETE FROM people WHERE id = ?", [.integer(person)])
                    } else {
                        try AnalysisStore.refreshCentroid(db, personId: person)
                    }
                }
            }
            if let albumId { try Albums.delete(db, albumId, forgetDecisions: true) }
        }
        for path in files { try? FileManager.default.removeItem(atPath: path) }
        guard case .object(var out) = plan else { return plan }
        out["done"] = .bool(true)
        return .object(out)
    }

    private static func treeBytes(_ path: String) -> Int {
        guard let en = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let rel as String in en {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/" + rel)
            if attrs?[.type] as? FileAttributeType == .typeRegular { total += (attrs?[.size] as? Int) ?? 0 }
        }
        return total
    }

    public static func usage(database: String) throws -> JSONValue {
        let db = try Database.open(path: database)
        var counts: [String: Int] = [:]
        for row in try db.query("SELECT availability, COUNT(*) AS n FROM images GROUP BY availability", []) {
            if case .text(let k)? = row["availability"] { counts[k] = int(row["n"]) ?? 0 }
        }
        var dbBytes = 0
        for p in [database, database + "-wal", database + "-shm"] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p) { dbBytes += (attrs[.size] as? Int) ?? 0 }
        }
        let parent = (database as NSString).deletingLastPathComponent
        var images: [String: JSONValue] = [:]
        for k in ["present", "missing", "archived"] { images[k] = .int(counts[k] ?? 0) }
        return .object([
            "database_bytes": .int(dbBytes),
            "proxies_bytes": .int(treeBytes(parent + "/proxies")),
            "feature_cache_bytes": .int(treeBytes(parent + "/feature-cache")),
            "images": .object(images),
        ])
    }
}
