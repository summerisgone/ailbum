import Foundation

public enum AnalysisStore {
    /// Port of `save_analysis`. Returns the run id from `manifest["run_id"]`.
    public static func save(
        database: String, source: String, output: String, manifest: JSONValue,
        records: [PhotoRecord], people: [PersonRecord], metadata: [ImageMetadata],
        faceSimilarity: Double, stories: [StoryRecord]?
    ) throws -> String {
        guard let runId = manifest["run_id"].map(text) else {
            throw AilbumError.invalid("В manifest нет run_id")
        }
        let db = try Database.open(path: database)
        try db.transaction {
            let sourceRoot = Catalog.resolve(isDirectory(source) ? source : (source as NSString).deletingLastPathComponent)
            try Catalog.markSourceMissing(db, sourceRoot: sourceRoot)
            var imageIds: [String: Int] = [:]
            for item in metadata {
                imageIds[item.path] = try Catalog.upsertImage(db, item)
            }
            try db.execute(
                """
                INSERT INTO analysis_runs (
                    id, source, output, started_at, completed_at, face_backend,
                    config_json, summary_json, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'completed')
                """,
                [.text(runId), .text(Catalog.resolve(source)), .text(Catalog.resolve(output)),
                 .text(text(manifest["started_at"])), .text(text(manifest["generated_at"])),
                 .text(text(manifest["face_backend"])),
                 .text(json(manifest["config"] ?? .null)), .text(json(manifest["summary"] ?? .null))])
            for record in records {
                guard let imageId = imageIds[record.path] else {
                    throw AilbumError.invalid("Нет метаданных для \(record.path)")
                }
                try insertPhoto(db, runId: runId, imageId: imageId, record: record)
                for (offset, face) in record.faces.enumerated() {
                    try insertFace(db, runId: runId, imageId: imageId, index: offset + 1, face: face, people: people)
                }
            }
            let clusterPeople = try assignPeople(db, runId: runId, people: people, faceSimilarity: faceSimilarity)
            try storeStories(db, runId: runId, stories: stories ?? [])
            for person in people {
                if let personId = clusterPeople[person.clusterId] ?? person.personId {
                    try refreshCentroid(db, personId: personId)
                }
            }
        }
        return runId
    }

    private static func insertPhoto(_ db: Database, runId: String, imageId: Int, record: PhotoRecord) throws {
        let sem = record.semantics
        let comp = record.composition
        let embedding = sem?.embedding.flatMap { Vectors.encode($0) }
        try db.execute(
            """
            INSERT INTO photo_analysis (
                run_id, image_id, photo_id, sharpness, exposure, quality,
                aesthetic_score, composition_score, rule_of_thirds,
                frame_occupancy, negative_space, crop_risk, color_balance,
                color_harmony, main_subject_json, scene_tags_json,
                object_tags_json, vision_embedding, vision_embedding_dim,
                vision_embedding_model, is_blurry, similar_cluster, story_id,
                selected, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(runId), .integer(imageId), .text(record.photoId), .real(record.sharpness),
             .real(record.exposure), .real(record.quality), real(sem?.aestheticScore),
             real(comp?.score), real(comp?.ruleOfThirds), real(comp?.frameOccupancy),
             real(comp?.negativeSpace), real(comp?.cropRisk), real(record.color?.balance),
             real(record.color?.harmony),
             comp?.mainSubject.map { .text(subjectJSON($0)) } ?? .null,
             .text(tagsJSON(sem?.scenes ?? [])), .text(tagsJSON(sem?.objects ?? [])),
             embedding.map { .blob($0) } ?? .null,
             (sem?.embedding?.isEmpty == false) ? .integer(sem!.embedding!.count) : .null,
             opt(sem?.model), .integer(record.isBlurry ? 1 : 0), opt(record.similarCluster),
             opt(record.storyId), .integer(record.selected ? 1 : 0), opt(record.error)])
    }

    private static func insertFace(
        _ db: Database, runId: String, imageId: Int, index: Int, face: FaceRecord, people: [PersonRecord]
    ) throws {
        let model = people.first { $0.clusterId == face.personCluster }?.embeddingModel
        let embedding = face.embedding.flatMap { Vectors.encode($0) }
        try db.execute(
            """
            INSERT INTO faces (
                run_id, image_id, face_id, face_index, bbox_x, bbox_y,
                bbox_width, bbox_height, confidence, person_cluster,
                person_id, embedding, embedding_dim, embedding_model,
                left_eye_state, right_eye_state, left_eye_open_probability,
                right_eye_open_probability, both_eyes_open, expression,
                expression_confidence, smile_probability, expression_scores_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(runId), .integer(imageId), .text(face.faceId), .integer(index),
             .integer(face.bbox.x), .integer(face.bbox.y), .integer(face.bbox.z), .integer(face.bbox.w),
             .real(face.confidence), opt(face.personCluster), opt(face.personId),
             embedding.map { .blob($0) } ?? .null,
             (face.embedding?.isEmpty == false) ? .integer(face.embedding!.count) : .null,
             opt(model), opt(face.eyes?.left), opt(face.eyes?.right),
             real(face.eyes?.leftOpenProbability), real(face.eyes?.rightOpenProbability),
             face.eyes?.bothOpen.map { .integer($0 ? 1 : 0) } ?? .null,
             opt(face.expression?.label), real(face.expression?.confidence),
             real(face.expression?.smileProbability),
             face.expression.map { .text(json(.object($0.scores.mapValues { .double($0) }))) } ?? .null])
    }

    // MARK: helpers

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    private static func opt(_ v: Int?) -> SQLValue { v.map { .integer($0) } ?? .null }
    private static func real(_ v: Double?) -> SQLValue { v.map { .real($0) } ?? .null }

    private static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?: return "\(d)"
        case .bool(let b)?: return b ? "True" : "False"
        default: return "None"
        }
    }

    private static func tagsJSON(_ tags: [TagRecord]) -> String {
        "[" + tags.map { "{\"label\":\(quote($0.label)),\"confidence\":\(number($0.confidence))}" }
            .joined(separator: ",") + "]"
    }

    private static func subjectJSON(_ s: SubjectRecord) -> String {
        let b = s.bbox
        return "{\"bbox\":[\(number(b.x)),\(number(b.y)),\(number(b.z)),\(number(b.w))],"
            + "\"center\":[\(number(s.center.x)),\(number(s.center.y))],\"source\":\(quote(s.source))}"
    }

    private static func number(_ d: Double) -> String { "\(d)" }

    private static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// Compact JSON like Python `json.dumps(ensure_ascii=False, separators=(",", ":"))`; object keys are sorted.
    static func json(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return number(d)
        case .string(let s): return quote(s)
        case .array(let a): return "[" + a.map(json).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { quote($0) + ":" + json(o[$0]!) }.joined(separator: ",") + "}"
        }
    }
}
