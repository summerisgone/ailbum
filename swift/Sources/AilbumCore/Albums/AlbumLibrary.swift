import CryptoKit
import Foundation

public enum AlbumLibrary {
    private static func int(_ v: SQLValue?) -> Int? {
        if case .integer(let i)? = v { return Int(i) }
        return nil
    }

    private static func count(_ db: Database, _ albumId: Int) throws -> Int {
        int(try db.query("SELECT COUNT(*) AS c FROM album_photos WHERE album_id = ?", [.integer(albumId)]).first?["c"]) ?? 0
    }

    private static func touch(_ db: Database, _ albumId: Int) throws {
        try db.execute("UPDATE albums SET updated_at = ? WHERE id = ?", [.text(Catalog.utcNow()), .integer(albumId)])
    }

    private static func event(_ db: Database, _ albumId: Int, _ runId: String?, _ imageId: Int,
                              _ action: String, _ source: String) throws {
        try db.execute(
            """
            INSERT INTO selection_events (album_id, run_id, image_id, action, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.integer(albumId), runId.map { .text($0) } ?? .null, .integer(imageId), .text(action), .text(source),
             .text(Catalog.utcNow())])
    }

    private static func add(_ db: Database, _ albumId: Int, _ runId: String?, _ imageId: Int,
                            _ action: String, _ source: String) throws {
        let position = int(try db.query(
            "SELECT COALESCE(MAX(position), 0) + 1 AS p FROM album_photos WHERE album_id = ?",
            [.integer(albumId)]).first?["p"]) ?? 1
        try db.execute("INSERT INTO album_photos (album_id, image_id, position, added_at) VALUES (?, ?, ?, ?)",
                       [.integer(albumId), .integer(imageId), .integer(position), .text(Catalog.utcNow())])
        try event(db, albumId, runId, imageId, action, source)
    }

    public static func setPhoto(_ db: Database, albumId: Int, imageId: Int, selected: Bool,
                                source: String = "manual") throws -> JSONValue {
        try Albums.requireDraft(db, albumId)
        let album = try Albums.get(db, albumId)
        let runId = album["run_id"]?.stringValue
        var changed = false
        try db.transaction {
            let present = !(try db.query("SELECT 1 FROM album_photos WHERE album_id = ? AND image_id = ?",
                                         [.integer(albumId), .integer(imageId)])).isEmpty
            if !present {
                var inRun = false
                if let runId {
                    inRun = !(try db.query("SELECT 1 FROM photo_analysis WHERE run_id = ? AND image_id = ?",
                                           [.text(runId), .integer(imageId)])).isEmpty
                }
                if !inRun { throw AilbumError.invalid("Image \(imageId) does not belong to album \(albumId)") }
            }
            if selected && !present {
                try add(db, albumId, runId, imageId, "add", source)
                changed = true
            } else if !selected && present {
                try db.execute("DELETE FROM album_photos WHERE album_id = ? AND image_id = ?",
                               [.integer(albumId), .integer(imageId)])
                try event(db, albumId, runId, imageId, "remove", source)
                changed = true
            }
            if changed { try touch(db, albumId) }
        }
        return [
            "album_id": .int(albumId), "image_id": .int(imageId), "favorite": .bool(selected),
            "changed": .bool(changed), "selected_count": .int(try count(db, albumId)),
        ]
    }

    public static func selectionHash(_ db: Database, albumId: Int) throws -> String {
        let ids = try db.query("SELECT image_id FROM album_photos WHERE album_id = ?", [.integer(albumId)])
            .compactMap { int($0["image_id"]) }.sorted()
        let digest = SHA256.hash(data: Data(ids.map(String.init).joined(separator: ",").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func setTarget(_ db: Database, albumId: Int, targetCount: Int) throws -> JSONValue {
        if !(1...999).contains(targetCount) { throw AilbumError.invalid("Selection target must be between 1 and 999") }
        try Albums.requireDraft(db, albumId)
        try db.execute("UPDATE albums SET target_count = ?, updated_at = ? WHERE id = ?",
                       [.integer(targetCount), .text(Catalog.utcNow()), .integer(albumId)])
        return ["album_id": .int(albumId), "target_count": .int(targetCount)]
    }

    private static func candidates(_ db: Database, runId: String) throws -> [RankingCandidate] {
        let rows = try db.query(
            """
            SELECT pa.image_id, pa.quality, pa.story_id, pa.similar_cluster,
                   pa.vision_embedding, pa.vision_embedding_dim
            FROM photo_analysis AS pa JOIN images AS i ON i.id = pa.image_id
            WHERE pa.run_id = ? AND pa.is_blurry = 0 AND pa.error IS NULL
              AND i.availability = 'present'
            ORDER BY pa.image_id
            """, [.text(runId)])
        var scores: [Int: Double] = [:]
        if let active = try RankingStore.activeModel(db, kind: "pointwise") {
            let vectors = try RankingFeatures.fromRows(db, runId: runId)
            let ids = rows.compactMap { int($0["image_id"]) }.filter { vectors[$0] != nil }
            if !ids.isEmpty {
                let values = active.model.score(ids.map { vectors[$0]! })
                for (i, v) in zip(ids, values) { scores[i] = v }
            }
        }
        return rows.compactMap { r in
            guard let imageId = int(r["image_id"]) else { return nil }
            var embedding: [Double]?
            if case .blob(let data)? = r["vision_embedding"], let dim = int(r["vision_embedding_dim"]) {
                let n = min(dim, data.count / 4)
                embedding = (0..<n).map { k in
                    let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self) }
                    return Double(Float(bitPattern: UInt32(littleEndian: bits)))
                }
            }
            var quality = 0.0
            switch r["quality"] {
            case .real(let q)?: quality = q
            case .integer(let q)?: quality = Double(q)
            default: break
            }
            return RankingCandidate(imageId: imageId, score: scores[imageId] ?? quality, storyId: int(r["story_id"]),
                                    similarCluster: int(r["similar_cluster"]), embedding: embedding)
        }
    }

    private static func seed(_ db: Database, album: JSONValue) throws {
        guard let albumId = album["id"]?.intValue, let runId = album["run_id"]?.stringValue,
              let target = album["target_count"]?.intValue else { return }
        let chosen = RankingSelect.selectForTarget(try candidates(db, runId: runId), target: target, keep: [])
        try db.transaction {
            for imageId in chosen { try add(db, albumId, runId, imageId, "seed", "auto") }
            if !chosen.isEmpty { try touch(db, albumId) }
        }
    }

    public static func autofill(_ db: Database, albumId: Int) throws -> JSONValue {
        try Albums.requireDraft(db, albumId)
        let album = try Albums.get(db, albumId)
        var added: [Int] = []
        if let runId = album["run_id"]?.stringValue, let target = album["target_count"]?.intValue {
            let keep = try db.query("SELECT image_id FROM album_photos WHERE album_id = ? ORDER BY position",
                                    [.integer(albumId)]).compactMap { int($0["image_id"]) }
            let chosen = RankingSelect.selectForTarget(try candidates(db, runId: runId), target: target, keep: keep)
            let kept = Set(keep)
            try db.transaction {
                for imageId in chosen where !kept.contains(imageId) {
                    try add(db, albumId, runId, imageId, "add", "auto")
                    added.append(imageId)
                }
                if !added.isEmpty { try touch(db, albumId) }
            }
        }
        return ["album_id": .int(albumId), "added": .array(added.map { .int($0) }),
                "selected_count": .int(try count(db, albumId))]
    }

    private static func noAnalysis(favorite: String, position: String, join: String, where clause: String) -> String {
        """
        SELECT i.id, i.path, i.file_name, i.width, i.height, i.orientation, i.taken_at,
               i.modified_at, i.availability, NULL AS quality, NULL AS sharpness,
               NULL AS exposure, NULL AS aesthetic_score,
               NULL AS composition_score, NULL AS rule_of_thirds,
               NULL AS frame_occupancy, NULL AS negative_space,
               NULL AS crop_risk, NULL AS color_balance,
               NULL AS color_harmony, NULL AS main_subject_json,
               '[]' AS scene_tags_json, '[]' AS object_tags_json,
               0 AS is_blurry, NULL AS similar_cluster, NULL AS story_id,
               NULL AS story_title, 0 AS auto_selected, 0 AS face_count, 0 AS people_count,
               0 AS closed_eyes_count, 0 AS smiling_faces_count,
               NULL AS people_names, \(favorite) AS favorite, \(position) AS selection_position
        FROM images AS i \(join)
        WHERE \(clause)
        ORDER BY COALESCE(i.taken_at, i.modified_at), i.path
        """
    }

    private static func photo(_ row: [String: SQLValue]) throws -> JSONValue {
        var out = JSONValue.row(row).objectValue ?? [:]
        for key in ["is_blurry", "auto_selected", "favorite"] {
            out[key] = .bool((out[key]?.doubleValue ?? 0) != 0)
        }
        out["people_names"] = .array(
            (out.removeValue(forKey: "people_names")?.stringValue ?? "")
                .split(separator: ",", omittingEmptySubsequences: true).map { .string(String($0)) })
        func parsed(_ key: String, _ fallback: String) throws -> JSONValue {
            let text = out.removeValue(forKey: key)?.stringValue
            return try JSONValue.parse(text ?? fallback)
        }
        let subject = out.removeValue(forKey: "main_subject_json")?.stringValue
        out["main_subject"] = (subject?.isEmpty ?? true) ? .null : try JSONValue.parse(subject!)
        out["scene_tags"] = try parsed("scene_tags_json", "[]")
        out["object_tags"] = try parsed("object_tags_json", "[]")
        return .object(out)
    }

    private static func defaultAlbumId(_ db: Database) throws -> Int? {
        int(try db.query(
            """
            SELECT id FROM albums
            ORDER BY (status = 'draft') DESC, updated_at DESC, id DESC LIMIT 1
            """, []).first?["id"])
    }

    public static func getLibrary(database: String, albumId: Int? = nil) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: database) else {
            throw AilbumError.invalid("Database does not exist: \(database)")
        }
        let db = try Database.open(path: database)
        let resolved = Catalog.resolve(database)
        guard let albumId = try albumId ?? defaultAlbumId(db) else {
            let rows = try db.query(noAnalysis(favorite: "0", position: "NULL", join: "",
                                               where: "i.availability = 'present'"), [])
            return [
                "database": .string(resolved), "album": .null, "albums": [], "run": .null, "target_count": 24,
                "selected_count": 0, "stories": [], "photos": .array(try rows.map(photo)),
            ]
        }
        let album = try Albums.get(db, albumId)
        let runId = album["run_id"]?.stringValue
        if album["status"] == "draft", runId != nil, try count(db, albumId) == 0,
           try db.query("SELECT 1 FROM selection_events WHERE album_id = ?", [.integer(albumId)]).isEmpty {
            try seed(db, album: album)
        }
        let memberJoin = "JOIN album_photos AS ap ON ap.image_id = i.id AND ap.album_id = ?"
        let memberSQL = noAnalysis(favorite: "1", position: "ap.position", join: memberJoin, where: "1 = 1")
        var rows: [[String: SQLValue]] = []
        var storyRows: [[String: SQLValue]] = []
        var runResult: JSONValue = .null
        var run: [String: SQLValue]?
        if let runId {
            run = try db.query(
                """
                SELECT id, source, started_at, completed_at, face_backend, summary_json
                FROM analysis_runs WHERE id = ?
                """, [.text(runId)]).first
        }
        if let runId, var run {
            try AnalysisStore.ensureStories(db, runId: runId)
            rows = try db.query(
                """
                WITH face_summary AS (
                    SELECT f.image_id,
                           COUNT(*) AS face_count,
                           COUNT(DISTINCT f.person_id) AS people_count,
                           SUM(CASE WHEN f.both_eyes_open = 0 THEN 1 ELSE 0 END)
                               AS closed_eyes_count,
                           SUM(CASE WHEN f.smile_probability >= 0.5 THEN 1 ELSE 0 END)
                               AS smiling_faces_count,
                           GROUP_CONCAT(DISTINCT NULLIF(TRIM(p.name), '')) AS people_names
                    FROM faces AS f
                    LEFT JOIN people AS p ON p.id = f.person_id
                    WHERE f.run_id = ?
                    GROUP BY f.image_id
                )
                SELECT i.id, i.path, i.file_name, i.width, i.height, i.orientation,
                       i.taken_at, i.modified_at, i.availability,
                       pa.quality, pa.sharpness, pa.exposure,
                       pa.aesthetic_score, pa.composition_score, pa.rule_of_thirds,
                       pa.frame_occupancy, pa.negative_space, pa.crop_risk,
                       pa.color_balance, pa.color_harmony, pa.main_subject_json,
                       pa.scene_tags_json, pa.object_tags_json,
                       pa.is_blurry, pa.similar_cluster, pa.story_id,
                       s.title AS story_title,
                       pa.selected AS auto_selected,
                       COALESCE(fs.face_count, 0) AS face_count,
                       COALESCE(fs.people_count, 0) AS people_count,
                       COALESCE(fs.closed_eyes_count, 0) AS closed_eyes_count,
                       COALESCE(fs.smiling_faces_count, 0) AS smiling_faces_count,
                       fs.people_names,
                       CASE WHEN ap.image_id IS NULL THEN 0 ELSE 1 END AS favorite,
                       ap.position AS selection_position
                FROM photo_analysis AS pa
                JOIN images AS i ON i.id = pa.image_id
                LEFT JOIN stories AS s
                    ON s.run_id = pa.run_id AND s.story_id = pa.story_id
                LEFT JOIN face_summary AS fs ON fs.image_id = i.id
                LEFT JOIN album_photos AS ap
                    ON ap.album_id = ? AND ap.image_id = i.id
                WHERE pa.run_id = ?
                ORDER BY pa.story_id, COALESCE(i.taken_at, i.modified_at), i.path
                """, [.text(runId), .integer(albumId), .text(runId)])
            let inRun = Set(rows.compactMap { int($0["id"]) })
            let extra = try db.query(memberSQL, [.integer(albumId)])
            rows += extra.filter { !inRun.contains(int($0["id"]) ?? -1) }
            storyRows = try db.query(
                """
                SELECT s.story_id AS id, s.title, s.started_at, s.ended_at,
                       s.representative_image_id, s.naming_model,
                       COUNT(pa.image_id) AS photo_count
                FROM stories AS s
                LEFT JOIN photo_analysis AS pa
                    ON pa.run_id = s.run_id AND pa.story_id = s.story_id
                WHERE s.run_id = ?
                GROUP BY s.run_id, s.story_id
                ORDER BY s.story_id
                """, [.text(runId)])
            let summary = run.removeValue(forKey: "summary_json")
            var obj = JSONValue.row(run).objectValue ?? [:]
            if case .text(let t)? = summary { obj["summary"] = try JSONValue.parse(t) }
            runResult = .object(obj)
        } else {
            rows = try db.query(memberSQL, [.integer(albumId)])
        }
        let photos = try rows.map(photo)
        return [
            "database": .string(resolved),
            "album": try Albums.get(db, albumId),
            "albums": try Albums.list(db),
            "run": runResult,
            "target_count": album["target_count"] ?? .null,
            "selected_count": .int(photos.filter { $0["favorite"] == true }.count),
            "stories": .array(storyRows.map { JSONValue.row($0) }),
            "photos": .array(photos),
        ]
    }
}
