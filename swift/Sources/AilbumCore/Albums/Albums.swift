import Foundation

public enum Albums {
    static let statusOrder = ["draft": 0, "ordered": 1, "archived": 2]
    static let transitions: Set<[String]> = [["draft", "ordered"], ["ordered", "draft"], ["ordered", "archived"]]

    private static func sortedUnique(_ items: [String]) -> [String] {
        Array(Set(items)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    public static func get(_ db: Database, _ albumId: Int) throws -> JSONValue {
        let rows = try db.query(
            """
            SELECT a.*, (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) AS photo_count
            FROM albums AS a WHERE a.id = ?
            """, [.integer(albumId)])
        guard let row = rows.first else { throw AilbumError.invalid("Альбом не найден") }
        let sources = try db.query(
            "SELECT source_root FROM album_sources WHERE album_id = ? ORDER BY source_root",
            [.integer(albumId)]
        ).compactMap { r -> JSONValue? in
            if case .text(let s)? = r["source_root"] { return .string(s) }
            return nil
        }
        func v(_ key: String) -> JSONValue { JSONValue(row[key] ?? .null) }
        return .object([
            "id": v("id"), "public_id": v("public_id"), "title": v("title"), "purpose": v("purpose"),
            "status": v("status"), "target_count": v("target_count"), "run_id": v("run_id"),
            "sources": .array(sources), "photo_count": v("photo_count"), "ordered_at": v("ordered_at"),
            "archived_at": v("archived_at"), "updated_at": v("updated_at"),
        ])
    }

    public static func create(_ db: Database, title: String, sources: [String], runId: String?, targetCount: Int) throws -> Int {
        let now = Catalog.utcNow()
        try db.execute(
            """
            INSERT INTO albums (public_id, title, target_count, run_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(UUID().uuidString.lowercased()), .text(title), .integer(targetCount),
             runId.map { .text($0) } ?? .null, .text(now), .text(now)])
        guard case .integer(let id)? = try db.query("SELECT last_insert_rowid() AS id", []).first?["id"] else {
            throw AilbumError.sqlite("no rowid")
        }
        for source in sortedUnique(sources) {
            try db.execute("INSERT INTO album_sources (album_id, source_root) VALUES (?, ?)", [.integer(id), .text(source)])
        }
        return Int(id)
    }

    public static func list(_ db: Database) throws -> JSONValue {
        let ids = try db.query("SELECT id FROM albums ORDER BY updated_at DESC, id DESC", []).compactMap { r -> Int? in
            if case .integer(let i)? = r["id"] { return Int(i) }
            return nil
        }
        let albums = try ids.map { try get(db, $0) }
        // stable by status: keeps updated_at DESC within a status
        var out: [JSONValue] = []
        for status in ["draft", "ordered", "archived"] {
            out += albums.filter { $0["status"]?.stringValue == status }
        }
        return .array(out)
    }

    public static func setStatus(_ db: Database, _ albumId: Int, _ status: String) throws -> JSONValue {
        let album = try get(db, albumId)
        let current = album["status"]?.stringValue ?? ""
        if current == status { return album }
        guard transitions.contains([current, status]) else {
            throw AilbumError.invalid("Переход \(current) -> \(status) недоступен")
        }
        let now = Catalog.utcNow()
        switch status {
        case "ordered":
            try db.execute("UPDATE albums SET status = ?, updated_at = ?, ordered_at = ? WHERE id = ?",
                           [.text(status), .text(now), .text(now), .integer(albumId)])
        case "draft":
            try db.execute("UPDATE albums SET status = ?, updated_at = ?, ordered_at = NULL WHERE id = ?",
                           [.text(status), .text(now), .integer(albumId)])
        default:
            try db.execute("UPDATE albums SET status = ?, updated_at = ?, archived_at = ? WHERE id = ?",
                           [.text(status), .text(now), .text(now), .integer(albumId)])
        }
        return try get(db, albumId)
    }

    public static func rename(_ db: Database, _ albumId: Int, title: String) throws -> JSONValue {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.unicodeScalars.count > 200 {
            throw AilbumError.invalid("Название должно быть от 1 до 200 символов")
        }
        _ = try get(db, albumId)
        try db.execute("UPDATE albums SET title = ?, updated_at = ? WHERE id = ?",
                       [.text(trimmed), .text(Catalog.utcNow()), .integer(albumId)])
        return try get(db, albumId)
    }

    public static func delete(_ db: Database, _ albumId: Int, forgetDecisions: Bool) throws {
        let album = try get(db, albumId)
        if album["status"]?.stringValue != "draft" && !forgetDecisions {
            throw AilbumError.invalid("Архивный альбом удаляется только с forget_decisions")
        }
        try db.execute("DELETE FROM albums WHERE id = ?", [.integer(albumId)])
    }

    public static func attachRun(_ db: Database, runId: String, sources: [String]) throws -> Int {
        let normalized = sortedUnique(sources)
        let drafts = try db.query("SELECT id FROM albums WHERE status = 'draft' ORDER BY updated_at DESC, id DESC", [])
        for row in drafts {
            guard case .integer(let raw)? = row["id"] else { continue }
            let albumId = Int(raw)
            let existing = try db.query(
                "SELECT source_root FROM album_sources WHERE album_id = ? ORDER BY source_root", [.integer(albumId)]
            ).compactMap { r -> String? in
                if case .text(let s)? = r["source_root"] { return s }
                return nil
            }
            if existing == normalized {
                try db.execute("UPDATE albums SET run_id = ?, updated_at = ? WHERE id = ?",
                               [.text(runId), .text(Catalog.utcNow()), .integer(albumId)])
                return albumId
            }
        }
        let name = normalized.first.flatMap { $0.split(separator: "/").last.map(String.init) } ?? ""
        let title = normalized.isEmpty ? "Альбом" : (name.isEmpty ? normalized[0] : name)
        return try create(db, title: title, sources: normalized, runId: runId, targetCount: 24)
    }

    public static func requireDraft(_ db: Database, _ albumId: Int) throws {
        if try get(db, albumId)["status"]?.stringValue != "draft" {
            throw AilbumError.invalid("Альбом заказан: изменения недоступны")
        }
    }
}
