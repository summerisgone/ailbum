import Foundation
import Testing
@testable import AilbumCore

private let goldenJSON = #"""
{"analysis_runs": [{"completed_at": "2024-05-01T10:01:00+00:00", "config_json": "{\"a\":1,\"b\":[1.0,\"x\"]}", "face_backend": "yunet", "id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "output": "<T>/out", "source": "<T>/src", "started_at": "2024-05-01T10:00:00+00:00", "status": "completed", "summary_json": "{\"photos\":2}"}], "faces": [{"bbox_height": 4, "bbox_width": 3, "bbox_x": 1, "bbox_y": 2, "both_eyes_open": 0, "confidence": 0.875, "embedding": "0000003f0000003f0000803e", "embedding_dim": 3, "embedding_model": "sface", "expression": "happy", "expression_confidence": 0.5, "expression_scores_json": "{\"happy\":0.5,\"neutral\":0.5}", "face_id": "f1", "face_index": 1, "id": 1, "image_id": 1, "left_eye_open_probability": 0.75, "left_eye_state": "open", "person_cluster": 0, "person_id": 1, "right_eye_open_probability": 0.125, "right_eye_state": "closed", "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "smile_probability": 0.5}, {"bbox_height": 4, "bbox_width": 3, "bbox_x": 1, "bbox_y": 2, "both_eyes_open": 0, "confidence": 0.875, "embedding": "0000003f0000003f0000803e", "embedding_dim": 3, "embedding_model": "sface", "expression": "happy", "expression_confidence": 0.5, "expression_scores_json": "{\"happy\":0.5,\"neutral\":0.5}", "face_id": "f2", "face_index": 1, "id": 2, "image_id": 2, "left_eye_open_probability": 0.75, "left_eye_state": "open", "person_cluster": 0, "person_id": 1, "right_eye_open_probability": 0.125, "right_eye_state": "closed", "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "smile_probability": 0.5}], "people": [{"centroid_embedding": "abaa2a3fabaa2a3fabaaaa3e", "embedding_dim": 3, "embedding_model": "sface", "id": 1, "name": null}], "photo_analysis": [{"aesthetic_score": 0.5, "color_balance": 0.5, "color_harmony": 0.25, "composition_score": 0.6, "crop_risk": 0.0, "error": null, "exposure": 0.5, "frame_occupancy": 0.25, "image_id": 1, "is_blurry": 0, "main_subject_json": "{\"bbox\":[0.1,0.2,0.3,0.4],\"center\":[0.25,0.5],\"source\":\"saliency\"}", "negative_space": 0.125, "object_tags_json": "[{\"label\":\"dog\",\"confidence\":0.25}]", "photo_id": "p1", "quality": 0.75, "rule_of_thirds": 0.5, "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "scene_tags_json": "[{\"label\":\"пляж\",\"confidence\":0.5},{\"label\":\"sea\",\"confidence\":1.0}]", "selected": 1, "sharpness": 120.5, "similar_cluster": 1, "story_id": 1, "vision_embedding": "0000003f0000803e000080bf00000040", "vision_embedding_dim": 4, "vision_embedding_model": "clip"}, {"aesthetic_score": null, "color_balance": 0.5, "color_harmony": 0.25, "composition_score": 0.6, "crop_risk": 0.0, "error": null, "exposure": 0.5, "frame_occupancy": 0.25, "image_id": 2, "is_blurry": 1, "main_subject_json": "{\"bbox\":[0.1,0.2,0.3,0.4],\"center\":[0.25,0.5],\"source\":\"saliency\"}", "negative_space": 0.125, "object_tags_json": "[]", "photo_id": "p2", "quality": 0.75, "rule_of_thirds": 0.5, "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "scene_tags_json": "[]", "selected": 0, "sharpness": 120.5, "similar_cluster": 2, "story_id": 1, "vision_embedding": null, "vision_embedding_dim": null, "vision_embedding_model": null}], "stories": [{"algorithm_version": 9, "ended_at": "2024-05-01T10:00:00", "naming_model": null, "object_tags_json": "[\"dog\"]", "representative_image_id": 1, "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "scene_tags_json": "[\"пляж\"]", "started_at": "2024-05-01T10:00:00", "story_id": 1, "title": "Пляж"}]}
"""#

private func makeTemp() throws -> (dir: String, src: String, db: String) {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    let src = dir + "/src"
    try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
    return (dir, src, dir + "/c.sqlite3")
}

private func meta(_ n: String, _ src: String) -> ImageMetadata {
    ImageMetadata(path: "\(src)/\(n).jpg", sourceRoot: src, relativePath: "\(n).jpg", fileName: "\(n).jpg",
                  extension: ".jpg", fileSizeBytes: 10, modifiedAt: "2024-05-01T10:00:00", sha256: "s" + n,
                  width: 40, height: 30, takenAt: "2024-05-01T10:00:00")
}

private func record(_ i: Int, _ m: ImageMetadata) -> PhotoRecord {
    PhotoRecord(
        photoId: "p\(i)", path: m.path, width: 40, height: 30, takenAt: "2024-05-01T10:00:00",
        sharpness: 120.5, exposure: 0.5, quality: 0.75, isBlurry: i == 2,
        composition: CompositionRecord(ruleOfThirds: 0.5, frameOccupancy: 0.25, negativeSpace: 0.125, cropRisk: 0.0,
            score: 0.6, mainSubject: SubjectRecord(bbox: SIMD4(0.1, 0.2, 0.3, 0.4), center: SIMD2(0.25, 0.5), source: "saliency")),
        color: ColorRecord(balance: 0.5, harmony: 0.25, meanSaturation: 0.3),
        semantics: i == 1 ? SemanticRecord(aestheticScore: 0.5, model: "clip",
            scenes: [TagRecord(label: "пляж", confidence: 0.5), TagRecord(label: "sea", confidence: 1.0)],
            objects: [TagRecord(label: "dog", confidence: 0.25)], embedding: [0.5, 0.25, -1.0, 2.0]) : nil,
        similarCluster: i, storyId: 1, selected: i == 1,
        faces: [FaceRecord(faceId: "f\(i)", bbox: SIMD4(1, 2, 3, 4), confidence: 0.875, personCluster: 0,
            embedding: [0.5, 0.5, 0.25],
            eyes: EyeStateRecord(left: "open", right: "closed", leftOpenProbability: 0.75, rightOpenProbability: 0.125, bothOpen: false),
            expression: ExpressionRecord(label: "happy", confidence: 0.5, smileProbability: 0.5,
                                         scores: ["happy": 0.5, "neutral": 0.5]))])
}

private func manifest(_ runId: String) -> JSONValue {
    ["run_id": .string(runId), "started_at": "2024-05-01T10:00:00+00:00", "generated_at": "2024-05-01T10:01:00+00:00",
     "face_backend": "yunet", "config": ["a": 1, "b": [1.0, "x"]], "summary": ["photos": 2]]
}

private func save(_ t: (dir: String, src: String, db: String), runId: String, people: Bool = true, stories: Bool = true) throws -> String {
    let ms = [meta("1", t.src), meta("2", t.src)]
    let rs = [record(1, ms[0]), record(2, ms[1])]
    let ppl = people ? [PersonRecord(clusterId: 0, faceIds: ["f1", "f2"], photoIds: ["p1", "p2"], embeddingModel: "sface", centroid: [0.6, 0.8, 0.0])] : []
    let st = stories ? [StoryRecord(storyId: 1, title: "Пляж", photoIds: ["p1", "p2"], startedAt: "2024-05-01T10:00:00",
                                    endedAt: "2024-05-01T10:00:00", representativePhotoId: "p1", sceneLabels: ["пляж"], objectLabels: ["dog"])] : []
    return try AnalysisStore.save(database: t.db, source: t.src, output: t.dir + "/out", manifest: manifest(runId),
                                  records: rs, people: ppl, metadata: ms, faceSimilarity: 0.5, stories: st)
}

private func dump(_ db: Database, _ table: String, _ order: String, drop: Set<String> = []) throws -> JSONValue {
    let rows = try db.query("SELECT * FROM \(table) ORDER BY \(order)", [])
    return .array(rows.map { row in
        var obj: [String: JSONValue] = [:]
        for (k, v) in row where !drop.contains(k) {
            if case .blob(let d) = v { obj[k] = .string(d.map { String(format: "%02x", $0) }.joined()) } else { obj[k] = JSONValue(v) }
        }
        return .object(obj)
    })
}

/// JSON "0.0" may decode as an integer; compare numbers as doubles.
private func norm(_ v: JSONValue) -> JSONValue {
    switch v {
    case .int(let i): return .double(Double(i))
    case .array(let a): return .array(a.map(norm))
    case .object(let o): return .object(o.mapValues(norm))
    default: return v
    }
}

@Test func testSaveAnalysisRowsMatchPython() throws {
    let t = try makeTemp()
    let runId = String(repeating: "a", count: 32)
    #expect(try save(t, runId: runId) == runId)
    let db = try Database.open(path: t.db)
    let golden = try JSONDecoder().decode(JSONValue.self, from: Data(goldenJSON.replacingOccurrences(of: "<T>", with: t.dir).utf8))
    #expect(norm(try dump(db, "photo_analysis", "image_id")) == norm(golden["photo_analysis"]!))
    #expect(norm(try dump(db, "faces", "id")) == norm(golden["faces"]!))
    #expect(norm(try dump(db, "analysis_runs", "id")) == norm(golden["analysis_runs"]!))
    #expect(norm(try dump(db, "stories", "story_id")) == norm(golden["stories"]!))
    #expect(norm(try dump(db, "people", "id", drop: ["public_id", "created_at", "updated_at"])) == norm(golden["people"]!))
}

@Test func testSaveTwoRecordsOneFaceEach() throws {
    let t = try makeTemp()
    let runId = try save(t, runId: Catalog.newRunId(), people: false, stories: false)
    #expect(runId.count == 36)
    let db = try Database.open(path: t.db)
    #expect(try db.query("SELECT COUNT(*) AS n FROM photo_analysis", []) == [["n": .integer(2)]])
    #expect(try db.query("SELECT COUNT(*) AS n FROM faces", []) == [["n": .integer(2)]])
}

@Test func testResaveCreatesNewRunAndKeepsEarlierRows() throws {
    let t = try makeTemp()
    _ = try save(t, runId: String(repeating: "a", count: 32))
    _ = try save(t, runId: String(repeating: "b", count: 32))
    let db = try Database.open(path: t.db)
    #expect(try db.query("SELECT COUNT(*) AS n FROM analysis_runs", []) == [["n": .integer(2)]])
    #expect(try db.query("SELECT COUNT(*) AS n FROM photo_analysis WHERE run_id = ?", [.text(String(repeating: "a", count: 32))]) == [["n": .integer(2)]])
    #expect(try db.query("SELECT COUNT(*) AS n FROM images", []) == [["n": .integer(2)]])
    // the matched person keeps its id across runs
    #expect(try db.query("SELECT COUNT(*) AS n FROM people", []) == [["n": .integer(1)]])
    #expect(try db.query("SELECT DISTINCT person_id FROM faces", []) == [["person_id": .integer(1)]])
}
