import Foundation
import Testing
@testable import AilbumCore

private func openDB() throws -> Database {
    try Database.open(path: NSTemporaryDirectory() + "ailbum-\(UUID().uuidString)/a.sqlite3")
}

private func seedRun(_ db: Database, _ runId: String, config: String = #"{"story_naming_backend":"off"}"#) throws {
    try db.execute(
        "INSERT INTO analysis_runs VALUES (?, 's', 'o', 't', 't', 'f', ?, '{}', 'completed')",
        [.text(runId), .text(config)])
}

private func seedPhoto(_ db: Database, _ runId: String, _ n: Int, takenAt: String?, storyId: Int? = nil) throws {
    try db.execute(
        """
        INSERT INTO images (id, path, source_root, relative_path, file_name, extension, file_size_bytes,
            modified_at, sha256, taken_at, exif_json, container_metadata_json, indexed_at)
        VALUES (?, ?, 's', ?, ?, 'jpg', 1, '2024-05-01T10:00:00', ?, ?, '{}', '{}', 't')
        """,
        [.integer(n), .text("/s/\(n).jpg"), .text("\(n).jpg"), .text("\(n).jpg"), .text("sha\(n)"),
         takenAt.map { .text($0) } ?? .null])
    try db.execute(
        """
        INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,
            is_blurry, story_id, selected) VALUES (?, ?, ?, 1, 1, 0.5, 0, ?, 0)
        """,
        [.text(runId), .integer(n), .text("p\(n)"), storyId.map { .integer($0) } ?? .null])
}

private func seedFace(_ db: Database, _ runId: String, _ n: Int, embedding: [Float], model: String = "m",
                      personId: Int? = nil, cluster: Int? = nil) throws {
    try db.execute(
        """
        INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
            confidence, person_cluster, person_id, embedding, embedding_dim, embedding_model)
        VALUES (?, ?, ?, 1, 0, 0, 1, 1, 1.0, ?, ?, ?, ?, ?)
        """,
        [.text(runId), .integer(n), .text("f\(runId)\(n)"), cluster.map { .integer($0) } ?? .null,
         personId.map { .integer($0) } ?? .null, .blob(Vectors.encode(embedding)!),
         .integer(embedding.count), .text(model)])
}

private func person(_ cluster: Int, _ centroid: [Float], model: String = "m") -> PersonRecord {
    PersonRecord(clusterId: cluster, faceIds: [], photoIds: [], embeddingModel: model, centroid: centroid)
}

private func count(_ db: Database, _ table: String) throws -> Int {
    guard case .integer(let n)? = try db.query("SELECT COUNT(*) AS c FROM \(table)", []).first?["c"] else { return -1 }
    return Int(n)
}

@Test func testRefreshCentroidIsNormalisedMean() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try seedPhoto(db, "r1", 1, takenAt: nil)
    try seedPhoto(db, "r1", 2, takenAt: nil)
    try db.execute(
        "INSERT INTO people VALUES (1, 'u1', NULL, 'm', ?, 2, 't', 't')", [.blob(Vectors.encode([1, 0])!)])
    try seedFace(db, "r1", 1, embedding: [2, 0], personId: 1)
    try seedFace(db, "r1", 2, embedding: [0, 3], personId: 1)
    try AnalysisStore.refreshCentroid(db, personId: 1)
    let row = try db.query("SELECT centroid_embedding, embedding_dim FROM people WHERE id = 1", [])[0]
    guard case .blob(let blob)? = row["centroid_embedding"] else { Issue.record("no blob"); return }
    let centroid = Vectors.decode(blob, dimension: 2)
    let expected = Float(1 / 2.0.squareRoot())
    #expect(abs(centroid[0] - expected) < 1e-6)
    #expect(abs(centroid[1] - expected) < 1e-6)
    #expect(row["embedding_dim"] == .integer(2))
}

@Test func testPersonKeepsIdAcrossRuns() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try seedPhoto(db, "r1", 1, takenAt: nil)
    try seedFace(db, "r1", 1, embedding: [1, 0], cluster: 0)
    try AnalysisStore.assignPeople(db, runId: "r1", people: [person(0, [1, 0])], faceSimilarity: 0.5)
    #expect(try count(db, "people") == 1)
    try seedRun(db, "r2")
    try seedPhoto(db, "r2", 2, takenAt: nil)
    try seedFace(db, "r2", 2, embedding: [0.99, 0.1], cluster: 4)
    try AnalysisStore.assignPeople(db, runId: "r2", people: [person(4, [0.99, 0.1])], faceSimilarity: 0.9)
    #expect(try count(db, "people") == 1)
    let ids = try db.query("SELECT person_id FROM faces ORDER BY id", [])
    #expect(ids.map { $0["person_id"] } == [.integer(1), .integer(1)])
}

@Test func testNewPersonWhenModelDiffersOrBelowThreshold() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try AnalysisStore.assignPeople(db, runId: "r1", people: [person(0, [1, 0])], faceSimilarity: 0.5)
    try AnalysisStore.assignPeople(db, runId: "r1", people: [person(0, [1, 0], model: "other")], faceSimilarity: 0.5)
    try AnalysisStore.assignPeople(db, runId: "r1", people: [person(0, [0, 1])], faceSimilarity: 0.5)
    #expect(try count(db, "people") == 3)
}

@Test func testEnsureStoriesEmptyRunWritesNothing() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try AnalysisStore.ensureStories(db, runId: "r1")
    #expect(try count(db, "stories") == 0)
}

@Test func testEnsureStoriesNoOpWhenCurrent() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try seedPhoto(db, "r1", 1, takenAt: "2024-05-01T10:00:00", storyId: 7)
    try db.execute(
        "INSERT INTO stories (run_id, story_id, title, algorithm_version) VALUES ('r1', 7, 'keep', ?)",
        [.integer(Stories.algorithmVersion)])
    try AnalysisStore.ensureStories(db, runId: "r1")
    #expect(try db.query("SELECT title FROM stories", []).map { $0["title"] } == [.text("keep")])
}

@Test func testEnsureStoriesRebuildsOldVersionAndAssigns() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try seedPhoto(db, "r1", 1, takenAt: "2024-05-01T10:00:00", storyId: 7)
    try seedPhoto(db, "r1", 2, takenAt: "2024-05-01T10:05:00", storyId: 7)
    try db.execute(
        "INSERT INTO stories (run_id, story_id, title, algorithm_version) VALUES ('r1', 7, 'old', 1)", [])
    try AnalysisStore.ensureStories(db, runId: "r1")
    let stories = try db.query("SELECT * FROM stories", [])
    #expect(stories.count == 1)
    #expect(stories[0]["title"] != .text("old"))
    #expect(stories[0]["algorithm_version"] == .integer(Stories.algorithmVersion))
    let assigned = try db.query("SELECT story_id FROM photo_analysis", [])
    #expect(assigned.allSatisfy { $0["story_id"] == stories[0]["story_id"] })
}

@Test func testStoreStoriesReplacesRows() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try seedPhoto(db, "r1", 1, takenAt: nil)
    let story = StoryRecord(storyId: 1, title: "Поездка", photoIds: ["p1"], startedAt: "a", endedAt: "b",
                            representativePhotoId: "p1", sceneLabels: ["пляж"], objectLabels: [])
    try AnalysisStore.storeStories(db, runId: "r1", stories: [story])
    try AnalysisStore.storeStories(db, runId: "r1", stories: [story])
    let rows = try db.query("SELECT * FROM stories", [])
    #expect(rows.count == 1)
    #expect(rows[0]["representative_image_id"] == .integer(1))
    #expect(rows[0]["scene_tags_json"] == .text(#"["пляж"]"#))
    #expect(rows[0]["object_tags_json"] == .text("[]"))
}

@Test func testEnsureStoriesHonoursVlmImagesConfig() throws {
    let db = try openDB()
    try seedRun(db, "r1", config: #"{"story_naming_backend":"off","story_vlm_images":9}"#)
    try seedPhoto(db, "r1", 1, takenAt: "2024-05-01T10:00:00")
    #expect(throws: AilbumError.self) { try AnalysisStore.ensureStories(db, runId: "r1") }
}

@Test func testEnsureStoriesHugeConfigNumbersDoNotTrap() throws {
    let db = try openDB()
    try seedRun(db, "r1", config: #"{"story_naming_backend":"off","story_gap_minutes":1e30,"story_continuity_minutes":1e30}"#)
    try seedPhoto(db, "r1", 1, takenAt: "2024-05-01T10:00:00")
    try AnalysisStore.ensureStories(db, runId: "r1")
    #expect(try count(db, "stories") == 1)
}

@Test func testRefreshCentroidKeepsCentroidWhenEmbeddingsAreCorrupt() throws {
    let db = try openDB()
    try seedRun(db, "r1")
    try seedPhoto(db, "r1", 1, takenAt: nil)
    try db.execute(
        "INSERT INTO people VALUES (1, 'u1', NULL, 'm', ?, 2, 't', 't')", [.blob(Vectors.encode([1, 0])!)])
    try db.execute(
        """
        INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y, bbox_width, bbox_height,
            confidence, person_id, embedding, embedding_dim, embedding_model)
        VALUES ('r1', 1, 'f', 1, 0, 0, 1, 1, 1.0, 1, ?, 8, 'm')
        """, [.blob(Data([1, 2, 3]))])
    try AnalysisStore.refreshCentroid(db, personId: 1)
    let row = try db.query("SELECT centroid_embedding, embedding_dim FROM people WHERE id = 1", [])[0]
    #expect(row["centroid_embedding"] == .blob(Vectors.encode([1, 0])!))
    #expect(row["embedding_dim"] == .integer(2))
}
