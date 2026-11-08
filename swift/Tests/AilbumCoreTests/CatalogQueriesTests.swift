import Foundation
import Testing
@testable import AilbumCore

private let goldenJSON = #"""
{"err": "Image id does not exist: 99", "image": {"analysis_history": [{"aesthetic_score": 0.5, "color_balance": 0.5, "color_harmony": 0.25, "completed_at": "2024-05-01T10:01:00+00:00", "composition_score": 0.6, "crop_risk": 0.0, "error": null, "exposure": 0.5, "face_backend": "yunet", "frame_occupancy": 0.25, "image_id": 1, "is_blurry": 0, "main_subject": {"bbox": [0.1, 0.2, 0.3, 0.4], "center": [0.25, 0.5], "source": "saliency"}, "negative_space": 0.125, "object_tags": [{"confidence": 0.25, "label": "dog"}], "photo_id": "p1", "quality": 0.75, "rule_of_thirds": 0.5, "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "scene_tags": [{"confidence": 0.5, "label": "пляж"}, {"confidence": 1.0, "label": "sea"}], "selected": 1, "sharpness": 120.5, "similar_cluster": 1, "started_at": "2024-05-01T10:00:00+00:00", "story_id": 1, "vision_embedding": null, "vision_embedding_dim": 4, "vision_embedding_model": "clip"}], "availability": "present", "camera_make": null, "camera_model": null, "color_mode": null, "container_metadata": {}, "created_at": null, "exif": {}, "extension": ".jpg", "extraction_error": null, "faces": [{"bbox_height": 4, "bbox_width": 3, "bbox_x": 1, "bbox_y": 2, "both_eyes_open": false, "confidence": 0.875, "embedding_dim": 3, "embedding_model": "sface", "expression": "happy", "expression_confidence": 0.5, "expression_scores": {"happy": 0.5, "neutral": 0.5}, "face_id": "f1", "face_index": 1, "id": 1, "image_id": 1, "left_eye_open_probability": 0.75, "left_eye_state": "open", "person_cluster": 0, "person_id": 1, "person_name": null, "person_public_id": "<P>", "right_eye_open_probability": 0.125, "right_eye_state": "closed", "run_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "smile_probability": 0.5}], "file_name": "1.jpg", "file_size_bytes": 10, "frame_count": null, "gps_altitude": null, "gps_latitude": null, "gps_longitude": null, "height": 30, "id": 1, "image_format": null, "indexed_at": "<I>", "lens_model": null, "mime_type": null, "modified_at": "2024-05-01T10:00:00", "orientation": null, "path": "<T>/src/1.jpg", "relative_path": "1.jpg", "sha256": "s1", "software": null, "source_root": "<T>/src", "taken_at": "2024-05-01T10:00:00", "width": 40}, "list": [{"availability": "present", "camera_make": null, "camera_model": null, "file_size_bytes": 10, "gps_latitude": null, "gps_longitude": null, "height": 30, "id": 1, "path": "<T>/src/1.jpg", "taken_at": "2024-05-01T10:00:00", "width": 40}, {"availability": "present", "camera_make": null, "camera_model": null, "file_size_bytes": 10, "gps_latitude": null, "gps_longitude": null, "height": 30, "id": 2, "path": "<T>/src/2.jpg", "taken_at": "2024-05-01T10:00:00", "width": 40}], "summary": {"analysis_runs": 1, "availability": {"archived": 0, "missing": 0, "present": 2}, "available": 2, "bytes": 20, "faces": 2, "images": 2, "linked_faces": 2, "people": 1, "stories": 1, "unique_files": 2, "with_gps": 0, "with_taken_at": 2}}
"""#

private func makeTempQ() throws -> (dir: String, src: String, db: String) {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    let src = dir + "/src"
    try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
    return (dir, src, dir + "/c.sqlite3")
}

private func metaQ(_ n: String, _ src: String) -> ImageMetadata {
    ImageMetadata(path: "\(src)/\(n).jpg", sourceRoot: src, relativePath: "\(n).jpg", fileName: "\(n).jpg",
                  extension: ".jpg", fileSizeBytes: 10, modifiedAt: "2024-05-01T10:00:00", sha256: "s" + n,
                  width: 40, height: 30, takenAt: "2024-05-01T10:00:00")
}

private func recordQ(_ i: Int, _ m: ImageMetadata) -> PhotoRecord {
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

private func manifestQ(_ runId: String) -> JSONValue {
    ["run_id": .string(runId), "started_at": "2024-05-01T10:00:00+00:00", "generated_at": "2024-05-01T10:01:00+00:00",
     "face_backend": "yunet", "config": ["a": 1, "b": [1.0, "x"]], "summary": ["photos": 2]]
}

private func saveQ(_ t: (dir: String, src: String, db: String), runId: String, people: Bool = true, stories: Bool = true) throws -> String {
    let ms = [metaQ("1", t.src), metaQ("2", t.src)]
    let rs = [recordQ(1, ms[0]), recordQ(2, ms[1])]
    let ppl = people ? [PersonRecord(clusterId: 0, faceIds: ["f1", "f2"], photoIds: ["p1", "p2"], embeddingModel: "sface", centroid: [0.6, 0.8, 0.0])] : []
    let st = stories ? [StoryRecord(storyId: 1, title: "Пляж", photoIds: ["p1", "p2"], startedAt: "2024-05-01T10:00:00",
                                    endedAt: "2024-05-01T10:00:00", representativePhotoId: "p1", sceneLabels: ["пляж"], objectLabels: ["dog"])] : []
    return try AnalysisStore.save(database: t.db, source: t.src, output: t.dir + "/out", manifest: manifestQ(runId),
                                  records: rs, people: ppl, metadata: ms, faceSimilarity: 0.5, stories: st)
}


/// JSON "0.0" may decode as an integer; compare numbers as doubles.
private func normQ(_ v: JSONValue) -> JSONValue {
    switch v {
    case .int(let i): return .double(Double(i))
    case .array(let a): return .array(a.map(normQ))
    case .object(let o): return .object(o.mapValues(normQ))
    default: return v
    }
}


private func fixture() throws -> (t: (dir: String, src: String, db: String), golden: JSONValue) {
    let t = try makeTempQ()
    _ = try saveQ(t, runId: String(repeating: "a", count: 32))
    let golden = try JSONDecoder().decode(JSONValue.self, from: Data(goldenJSON.replacingOccurrences(of: "<T>", with: t.dir).utf8))
    return (t, golden)
}

@Test func testSummaryMatchesPython() throws {
    let f = try fixture()
    #expect(normQ(try CatalogQueries.summary(database: f.t.db)) == normQ(f.golden["summary"]!))
}

@Test func testListImagesMatchesPython() throws {
    let f = try fixture()
    #expect(normQ(try CatalogQueries.listImages(database: f.t.db, limit: 100)) == normQ(f.golden["list"]!))
    #expect(try CatalogQueries.listImages(database: f.t.db, limit: 1).arrayValue?.count == 1)
}

@Test func testGetImageMatchesPython() throws {
    let f = try fixture()
    guard case .object(var image) = try CatalogQueries.getImage(database: f.t.db, imageId: 1) else {
        Issue.record("not an object"); return
    }
    #expect(image["indexed_at"]?.stringValue?.isEmpty == false)
    image["indexed_at"] = "<I>"
    if case .array(var faces)? = image["faces"], case .object(var face) = faces[0] {
        #expect(face["person_public_id"]?.stringValue?.isEmpty == false)
        face["person_public_id"] = "<P>"
        faces[0] = .object(face)
        image["faces"] = .array(faces)
    }
    #expect(normQ(.object(image)) == normQ(f.golden["image"]!))
}

@Test func testUnknownImageIdUsesPythonError() throws {
    let f = try fixture()
    #expect(throws: AilbumError.invalid(f.golden["err"]!.stringValue!)) {
        try CatalogQueries.getImage(database: f.t.db, imageId: 99)
    }
}

@Test func testMissingDatabaseUsesPythonError() throws {
    let path = NSTemporaryDirectory() + "nope-\(UUID().uuidString).sqlite3"
    #expect(throws: AilbumError.invalid("Database does not exist: \(path)")) {
        try CatalogQueries.summary(database: path)
    }
}
