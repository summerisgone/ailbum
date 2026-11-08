import Foundation

extension AnalysisStore {
    /// Port of `_assign_people`. Faces of `runId` are already stored; cluster ids map to person ids.
    @discardableResult
    static func assignPeople(_ db: Database, runId: String, people: [PersonRecord],
                             faceSimilarity: Double) throws -> [Int: Int] {
        let existing = try db.query("SELECT * FROM people", [])
        var clusterPeople: [Int: Int] = [:]
        for person in people {
            let compatible = existing.filter { row in
                row["embedding_model"] == .text(person.embeddingModel)
                    && row["embedding_dim"] == .integer(person.centroid.count)
            }
            var best: [String: SQLValue]?
            var bestSimilarity = -1.0
            for candidate in compatible {
                guard case .blob(let blob)? = candidate["centroid_embedding"],
                      case .integer(let dim)? = candidate["embedding_dim"] else { continue }
                let other = Vectors.decode(blob, dimension: Int(dim))
                var dot: Float = 0
                for (a, b) in zip(person.centroid, other) { dot += a * b }
                let similarity = Double(dot)
                if similarity > bestSimilarity {
                    best = candidate
                    bestSimilarity = similarity
                }
            }
            if let best, bestSimilarity >= faceSimilarity, case .integer(let id)? = best["id"] {
                clusterPeople[person.clusterId] = Int(id)
            } else {
                let now = Catalog.utcNow()
                try db.execute(
                    """
                    INSERT INTO people (
                        public_id, name, embedding_model, centroid_embedding,
                        embedding_dim, created_at, updated_at
                    ) VALUES (?, NULL, ?, ?, ?, ?, ?)
                    """,
                    [.text(UUID().uuidString.lowercased()), .text(person.embeddingModel),
                     blobOrNull(Vectors.encode(person.centroid)), .integer(person.centroid.count),
                     .text(now), .text(now)])
                let rowId = try db.query("SELECT last_insert_rowid() AS id", [])
                guard case .integer(let id)? = rowId.first?["id"] else { continue }
                clusterPeople[person.clusterId] = Int(id)
            }
        }
        for (cluster, personId) in clusterPeople {
            try db.execute(
                "UPDATE faces SET person_id = ? WHERE run_id = ? AND person_cluster = ?",
                [.integer(personId), .text(runId), .integer(cluster)])
        }
        return clusterPeople
    }

    /// Port of `_store_stories`; image ids come from the run's `photo_analysis` rows.
    static func storeStories(_ db: Database, runId: String, stories: [StoryRecord]) throws {
        try db.execute("DELETE FROM stories WHERE run_id = ?", [.text(runId)])
        var imageIds: [String: Int64] = [:]
        for row in try db.query("SELECT photo_id, image_id FROM photo_analysis WHERE run_id = ?", [.text(runId)]) {
            if case .text(let photo)? = row["photo_id"], case .integer(let image)? = row["image_id"] {
                imageIds[photo] = image
            }
        }
        for story in stories {
            try db.execute(
                """
                INSERT INTO stories (
                    run_id, story_id, title, started_at, ended_at,
                    representative_image_id, scene_tags_json, object_tags_json,
                    naming_model, algorithm_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(runId), .integer(story.storyId), .text(story.title),
                 textOrNull(story.startedAt), textOrNull(story.endedAt),
                 imageIds[story.representativePhotoId].map { .integer($0) } ?? .null,
                 .text(jsonStrings(story.sceneLabels)), .text(jsonStrings(story.objectLabels)),
                 textOrNull(story.namingModel), .integer(Stories.algorithmVersion)])
        }
    }

    /// Port of `_ensure_stories`.
    static func ensureStories(_ db: Database, runId: String) throws {
        let counts = try db.query(
            """
            SELECT COUNT(*) AS photos,
                   SUM(CASE WHEN story_id IS NOT NULL THEN 1 ELSE 0 END) AS assigned
            FROM photo_analysis WHERE run_id = ?
            """, [.text(runId)])
        let state = try db.query(
            """
            SELECT COUNT(*) AS stories,
                   MIN(COALESCE(algorithm_version, 1)) AS algorithm_version
            FROM stories WHERE run_id = ?
            """, [.text(runId)])
        let photoCount = intValue(counts.first?["photos"]) ?? 0
        let assigned = intValue(counts.first?["assigned"]) ?? 0
        let storyCount = intValue(state.first?["stories"]) ?? 0
        let version = intValue(state.first?["algorithm_version"]) ?? 1
        if photoCount == 0 { return }
        if storyCount > 0 && assigned == photoCount && version >= Stories.algorithmVersion { return }

        let rows = try db.query(
            """
            SELECT pa.photo_id, pa.image_id, pa.quality, pa.is_blurry,
                   pa.scene_tags_json, pa.object_tags_json,
                   pa.vision_embedding, pa.vision_embedding_dim,
                   i.taken_at, i.modified_at, i.file_name,
                   i.gps_latitude, i.gps_longitude, i.path
            FROM photo_analysis AS pa
            JOIN images AS i ON i.id = pa.image_id
            WHERE pa.run_id = ? AND i.availability = 'present'
            ORDER BY COALESCE(i.taken_at, i.modified_at), i.path
            """, [.text(runId)])
        var peopleByImage: [Int: Set<String>] = [:]
        for face in try db.query(
            "SELECT image_id, person_id, person_cluster FROM faces WHERE run_id = ?", [.text(runId)]) {
            guard let image = intValue(face["image_id"]) else { continue }
            if let person = intValue(face["person_id"]) {
                peopleByImage[image, default: []].insert("person:\(person)")
            } else if let cluster = intValue(face["person_cluster"]) {
                peopleByImage[image, default: []].insert("cluster:\(cluster)")
            }
        }
        let configRow = try db.query("SELECT config_json FROM analysis_runs WHERE id = ?", [.text(runId)])
        var config: [String: JSONValue] = [:]
        if case .text(let text)? = configRow.first?["config_json"],
           let value = try? JSONValue.parse(text),
           let object = value.objectValue {
            config = object
        }

        let photos: [StoryPhoto] = rows.map { row in
            var embedding: [Float]?
            if case .blob(let blob)? = row["vision_embedding"], let dim = intValue(row["vision_embedding_dim"]) {
                embedding = Vectors.decode(blob, dimension: dim)
            }
            let file = textValue(row["file_name"]) ?? ""
            return StoryPhoto(
                photoId: textValue(row["photo_id"]) ?? "",
                takenAt: nonEmpty(textValue(row["taken_at"])) ?? Metadata.filenameTakenAt(file)
                    ?? nonEmpty(textValue(row["modified_at"])),
                gpsLatitude: doubleValue(row["gps_latitude"]),
                gpsLongitude: doubleValue(row["gps_longitude"]),
                people: peopleByImage[intValue(row["image_id"]) ?? -1] ?? [],
                scenes: tagPairs(textValue(row["scene_tags_json"])),
                objects: tagPairs(textValue(row["object_tags_json"])),
                embedding: embedding,
                quality: doubleValue(row["quality"]) ?? 0,
                isBlurry: (intValue(row["is_blurry"]) ?? 0) != 0)
        }
        var stories = Stories.detect(
            photos,
            gapMinutes: configInt(config, "story_gap_minutes", 120),
            continuityMinutes: configInt(config, "story_continuity_minutes", 360),
            maxDurationHours: configInt(config, "story_max_duration_hours", 12))
        let namer = try StoryNamer(
            backend: config["story_naming_backend"]?.stringValue ?? "auto",
            baseURL: config["lmstudio_url"]?.stringValue ?? "http://127.0.0.1:1234/v1",
            model: config["lmstudio_model"]?.stringValue ?? "qwen/qwen3-vl-2b",
            maxImages: configInt(config, "story_vlm_images", 4),
            timeout: config["story_vlm_timeout"]?.doubleValue ?? 90.0)
        var paths: [String: String] = [:]
        for row in rows { paths[textValue(row["photo_id"]) ?? ""] = textValue(row["path"]) ?? "" }
        stories = try namer.refine(stories, photoPaths: paths)
        for story in stories {
            for photoId in story.photoIds {
                try db.execute(
                    "UPDATE photo_analysis SET story_id = ? WHERE run_id = ? AND photo_id = ?",
                    [.integer(story.storyId), .text(runId), .text(photoId)])
            }
        }
        try storeStories(db, runId: runId, stories: stories)
    }

    /// Port of `_refresh_person_centroid`.
    static func refreshCentroid(_ db: Database, personId: Int) throws {
        let person = try db.query("SELECT embedding_model FROM people WHERE id = ?", [.integer(personId)])
        guard let model = person.first?["embedding_model"] else { return }
        let rows = try db.query(
            """
            SELECT embedding, embedding_dim FROM faces
            WHERE person_id = ? AND embedding_model = ? AND embedding IS NOT NULL
            """, [.integer(personId), model])
        let embeddings: [[Float]] = rows.compactMap { row in
            guard case .blob(let blob)? = row["embedding"], let dim = intValue(row["embedding_dim"]) else { return nil }
            return Vectors.decode(blob, dimension: dim)
        }.filter { !$0.isEmpty }
        guard let first = embeddings.first else { return }
        var centroid = [Float](repeating: 0, count: first.count)
        for embedding in embeddings {
            for index in 0..<min(centroid.count, embedding.count) { centroid[index] += embedding[index] }
        }
        centroid = centroid.map { $0 / Float(embeddings.count) }
        let norm = centroid.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { centroid = centroid.map { $0 / norm } }
        try db.execute(
            "UPDATE people SET centroid_embedding = ?, embedding_dim = ?, updated_at = ? WHERE id = ?",
            [blobOrNull(Vectors.encode(centroid)), .integer(centroid.count),
             .text(Catalog.utcNow()), .integer(personId)])
    }

    // MARK: helpers

    private static func blobOrNull(_ data: Data?) -> SQLValue { data.map { .blob($0) } ?? .null }
    private static func textOrNull(_ text: String?) -> SQLValue { text.map { .text($0) } ?? .null }

    private static func intValue(_ value: SQLValue?) -> Int? {
        switch value {
        case .integer(let v)?: return Int(v)
        case .real(let v)?: return Int(v)
        default: return nil
        }
    }

    private static func doubleValue(_ value: SQLValue?) -> Double? {
        switch value {
        case .integer(let v)?: return Double(v)
        case .real(let v)?: return v
        default: return nil
        }
    }

    private static func textValue(_ value: SQLValue?) -> String? {
        if case .text(let v)? = value { return v }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func configInt(_ config: [String: JSONValue], _ key: String, _ fallback: Int) -> Int {
        if let v = config[key]?.intValue { return v }
        if let d = config[key]?.doubleValue, d.isFinite { return Int(max(-9e18, min(9e18, d))) }
        return fallback
    }

    /// Python `json.dumps(list[str], ensure_ascii=False, separators=(",", ":"))`.
    private static func jsonStrings(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    /// Port of `_tag_pairs`.
    private static func tagPairs(_ text: String?) -> [TagRecord] {
        let source = nonEmpty(text) ?? "[]"
        guard let items = (try? JSONValue.parse(source))?.arrayValue
        else { return [] }
        var result: [TagRecord] = []
        for item in items {
            if let object = item.objectValue {
                if let label = object["label"]?.stringValue, !label.isEmpty {
                    result.append(TagRecord(label: label, confidence: object["confidence"]?.doubleValue ?? 0))
                }
            } else if let label = item.stringValue {
                result.append(TagRecord(label: label, confidence: 1.0))
            }
        }
        return result
    }

}
