import Foundation

public enum CatalogQueries {
    private static func openExisting(_ database: String) throws -> Database {
        guard FileManager.default.fileExists(atPath: database) else {
            throw AilbumError.invalid("Database does not exist: \(database)")
        }
        return try Database.open(path: database)
    }

    private static func int(_ value: SQLValue?) -> Int {
        switch value {
        case .integer(let v)?: return Int(v)
        case .real(let v)?: return Int(v)
        default: return 0
        }
    }

    private static func parse(_ text: String) throws -> JSONValue {
        try JSONValue.parse(text)
    }

    /// Python `json.loads(value) if value else None`.
    private static func jsonOrNone(_ value: JSONValue?) throws -> JSONValue {
        guard case .string(let s)? = value, !s.isEmpty else { return .null }
        return try parse(s)
    }

    private static func parseTags(_ value: JSONValue?) throws -> JSONValue {
        guard case .string(let s)? = value else { return [] }
        return try parse(s)
    }

    public static func summary(database: String) throws -> JSONValue {
        let db = try openExisting(database)
        let c = try db.query(
            """
            SELECT COUNT(*) AS images,
                   SUM(CASE WHEN availability = 'present' THEN 1 ELSE 0 END) AS available,
                   COUNT(DISTINCT sha256) AS unique_files,
                   SUM(file_size_bytes) AS bytes,
                   SUM(CASE WHEN gps_latitude IS NOT NULL THEN 1 ELSE 0 END) AS with_gps,
                   SUM(CASE WHEN taken_at IS NOT NULL THEN 1 ELSE 0 END) AS with_taken_at
            FROM images
            """, [])[0]
        var states: [String: Int] = [:]
        for row in try db.query("SELECT availability AS a, COUNT(*) AS n FROM images GROUP BY availability", []) {
            if case .text(let a)? = row["a"] { states[a] = int(row["n"]) }
        }
        func count(_ sql: String) throws -> Int {
            int(try db.query(sql, []).first?["n"])
        }
        var result: [String: JSONValue] = [:]
        for key in ["images", "available", "unique_files", "bytes", "with_gps", "with_taken_at"] {
            result[key] = .int(int(c[key]))
        }
        result["availability"] = .object(Dictionary(
            uniqueKeysWithValues: ["present", "missing", "archived"].map { ($0, JSONValue.int(states[$0] ?? 0)) }))
        result["analysis_runs"] = .int(try count("SELECT COUNT(*) AS n FROM analysis_runs"))
        result["faces"] = .int(try count("SELECT COUNT(*) AS n FROM faces"))
        result["linked_faces"] = .int(try count("SELECT COUNT(*) AS n FROM faces WHERE person_id IS NOT NULL"))
        result["people"] = .int(try count("SELECT COUNT(*) AS n FROM people"))
        result["stories"] = .int(try count("SELECT COUNT(*) AS n FROM stories"))
        return .object(result)
    }

    public static func listImages(database: String, limit: Int) throws -> JSONValue {
        let db = try openExisting(database)
        let rows = try db.query(
            """
            SELECT id, path, taken_at, width, height, camera_make, camera_model,
                   gps_latitude, gps_longitude, file_size_bytes, availability
            FROM images
            ORDER BY COALESCE(taken_at, modified_at), path
            LIMIT ?
            """, [.integer(limit)])
        return .array(rows.map { JSONValue.row($0) })
    }

    public static func getImage(database: String, imageId: Int) throws -> JSONValue {
        let db = try openExisting(database)
        guard let row = try db.query("SELECT * FROM images WHERE id = ?", [.integer(imageId)]).first else {
            throw AilbumError.invalid("Image id does not exist: \(imageId)")
        }
        guard case .object(var result) = JSONValue.row(row) else { return .null }
        result["exif"] = try parse(result.removeValue(forKey: "exif_json")?.stringValue ?? "null")
        result["container_metadata"] = try parse(
            result.removeValue(forKey: "container_metadata_json")?.stringValue ?? "null")
        let history = try db.query(
            """
            SELECT pa.*, ar.started_at, ar.completed_at, ar.face_backend
            FROM photo_analysis AS pa
            JOIN analysis_runs AS ar ON ar.id = pa.run_id
            WHERE pa.image_id = ?
            ORDER BY ar.completed_at DESC
            """, [.integer(imageId)])
        result["analysis_history"] = .array(try history.map { item in
            guard case .object(var r) = JSONValue.row(item) else { return .null }
            r["main_subject"] = try jsonOrNone(r.removeValue(forKey: "main_subject_json"))
            r["scene_tags"] = try parseTags(r.removeValue(forKey: "scene_tags_json"))
            r["object_tags"] = try parseTags(r.removeValue(forKey: "object_tags_json"))
            return .object(r)
        })
        let faces = try db.query(
            """
            SELECT f.id, f.run_id, f.image_id, f.face_id, f.face_index,
                   f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                   f.confidence, f.person_cluster, f.person_id,
                   f.embedding_dim, f.embedding_model, f.left_eye_state,
                   f.right_eye_state, f.left_eye_open_probability,
                   f.right_eye_open_probability, f.both_eyes_open,
                   f.expression, f.expression_confidence,
                   f.smile_probability, f.expression_scores_json,
                   p.public_id AS person_public_id, p.name AS person_name
            FROM faces AS f
            LEFT JOIN people AS p ON p.id = f.person_id
            WHERE f.image_id = ?
            ORDER BY f.run_id, f.face_index
            """, [.integer(imageId)])
        result["faces"] = .array(try faces.map { item in
            guard case .object(var r) = JSONValue.row(item) else { return .null }
            r["expression_scores"] = try jsonOrNone(r.removeValue(forKey: "expression_scores_json"))
            if let open = r["both_eyes_open"]?.intValue { r["both_eyes_open"] = .bool(open != 0) }
            return .object(r)
        })
        return .object(result)
    }
}
