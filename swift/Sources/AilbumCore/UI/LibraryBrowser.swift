import Foundation

public struct AlbumRow: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let status: String
    public let selected: Int
    public let target: Int

    public init(id: Int, title: String, status: String, selected: Int, target: Int) {
        self.id = id; self.title = title; self.status = status; self.selected = selected; self.target = target
    }
}

public struct PhotoTile: Equatable, Identifiable, Sendable {
    public let imageId: Int
    public let path: String?
    public let selected: Bool
    public var id: Int { imageId }

    public init(imageId: Int, path: String?, selected: Bool) {
        self.imageId = imageId; self.path = path; self.selected = selected
    }
}

/// Read-only view of a library database for the preview window.
public enum LibraryBrowser {
    public static func albums(database: String) throws -> [AlbumRow] {
        let db = try Database.open(path: database)
        return try (Albums.list(db).arrayValue ?? []).map { a in
            AlbumRow(id: a["id"]?.intValue ?? 0, title: a["title"]?.stringValue ?? "",
                     status: a["status"]?.stringValue ?? "", selected: a["photo_count"]?.intValue ?? 0,
                     target: a["target_count"]?.intValue ?? 0)
        }
    }

    /// `albumId == nil` lists every indexed image; otherwise the album's run photos plus its members.
    public static func photos(database: String, albumId: Int?) throws -> [PhotoTile] {
        let db = try Database.open(path: database)
        var rows: [[String: SQLValue]]
        if let albumId {
            rows = try db.query(
                """
                SELECT i.id, i.path, i.sha256, i.availability,
                       CASE WHEN ap.image_id IS NULL THEN 0 ELSE 1 END AS sel
                FROM images AS i
                LEFT JOIN album_photos AS ap ON ap.album_id = ?1 AND ap.image_id = i.id
                WHERE ap.image_id IS NOT NULL OR i.id IN (
                    SELECT pa.image_id FROM photo_analysis AS pa
                    JOIN albums AS a ON a.run_id = pa.run_id WHERE a.id = ?1)
                ORDER BY COALESCE(i.taken_at, i.modified_at), i.path
                """, [.integer(albumId)])
        } else {
            rows = try db.query(
                """
                SELECT i.id, i.path, i.sha256, i.availability,
                       EXISTS (SELECT 1 FROM album_photos AS ap WHERE ap.image_id = i.id) AS sel
                FROM images AS i
                ORDER BY COALESCE(i.taken_at, i.modified_at), i.path
                """, [])
        }
        return rows.map { row in
            var id = 0
            if case .integer(let v)? = row["id"] { id = Int(v) }
            var sel = false
            if case .integer(let v)? = row["sel"] { sel = v != 0 }
            return PhotoTile(imageId: id, path: Proxies.imageSource(database: database, image: row), selected: sel)
        }
    }
}
