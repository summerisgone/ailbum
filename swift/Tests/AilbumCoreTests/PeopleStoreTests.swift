import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AilbumCore

private struct Env {
    let source: String
    let image: String
    let database: String
}

private func makeEnv() throws -> Env {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    let source = dir + "/photos"
    try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
    let image = source + "/portrait.jpg"
    let ctx = CGContext(data: nil, width: 240, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 80 / 255, green: 120 / 255, blue: 160 / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: image) as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    return Env(source: source, image: image, database: dir + "/catalog.sqlite3")
}

@discardableResult
private func saveRun(_ env: Env, _ runId: String, _ embedding: [Float], _ bbox: SIMD4<Int>) throws -> Int {
    let face = FaceRecord(
        faceId: "\(runId)-face", bbox: bbox, confidence: 0.95, personCluster: 1, embedding: embedding,
        eyes: EyeStateRecord(left: "open", right: "closed", leftOpenProbability: 0.91,
                             rightOpenProbability: 0.12, bothOpen: false),
        expression: ExpressionRecord(label: "happy", confidence: 0.84, smileProbability: 0.84,
                                     scores: ["happy": 0.84, "neutral": 0.16]))
    let photo = PhotoRecord(photoId: "\(runId)-photo", path: Catalog.resolve(env.image), width: 240, height: 180,
                            takenAt: nil, sharpness: 100, exposure: 1, quality: 1, isBlurry: false,
                            selected: true, faces: [face])
    let person = PersonRecord(clusterId: 1, faceIds: [face.faceId], photoIds: [photo.photoId],
                              embeddingModel: "test-model", centroid: embedding)
    let manifest: JSONValue = ["run_id": .string(runId), "started_at": "2026-08-07T10:00:00+00:00",
                               "generated_at": "2026-08-07T10:00:01+00:00", "face_backend": "test",
                               "config": [:], "summary": ["faces": 1, "people_groups": 1]]
    _ = try AnalysisStore.save(
        database: env.database, source: env.source, output: env.source + "/output", manifest: manifest,
        records: [photo], people: [person], metadata: [try Metadata.collect(path: env.image, source: env.source)],
        faceSimilarity: 0.8, stories: nil)
    let db = try Database.open(path: env.database)
    let rows = try db.query("SELECT person_id FROM faces WHERE face_id = ?", [.text(face.faceId)])
    guard case .integer(let id)? = rows.first?["person_id"] else { return 0 }
    return Int(id)
}

private func twoPeople() throws -> (Env, Int, Int) {
    let env = try makeEnv()
    let first = try saveRun(env, "run-1", [1, 0], SIMD4(10, 10, 60, 60))
    let second = try saveRun(env, "run-2", [0, 1], SIMD4(120, 30, 60, 60))
    return (env, first, second)
}

private func ids(_ value: JSONValue) -> [Int] { (value.arrayValue ?? []).compactMap { $0["id"]?.intValue } }

@Test func testPeopleAreStableAcrossRunsAndCanBeComposed() throws {
    let env = try makeEnv()
    let first = try saveRun(env, "run-1", [1, 0], SIMD4(20, 20, 80, 80))
    let second = try saveRun(env, "run-2", [0.999, 0.01], SIMD4(20, 20, 80, 80))
    #expect(first == second)
    #expect(try PeopleStore.list(database: env.database, limit: 100).arrayValue?.count == 1)
    let details = try PeopleStore.name(database: env.database, personId: first, name: "Alice")
    #expect(details["name"]?.stringValue == "Alice")
    #expect(details["face_count"]?.intValue == 2)
    let face = details["faces"]?[0]
    #expect(face?["left_eye_state"]?.stringValue == "open")
    #expect(face?["right_eye_state"]?.stringValue == "closed")
    #expect(face?["both_eyes_open"] == .bool(false))
    #expect(face?["expression"]?.stringValue == "happy")
    #expect(face?["expression_scores"]?["happy"]?.doubleValue == 0.84)

    let sheet = (env.source as NSString).deletingLastPathComponent + "/alice.jpg"
    let result = try PeopleStore.composeSheet(database: env.database, personId: first, output: sheet,
                                              faceSize: 180, columns: 5)
    #expect(result["faces"]?.intValue == 1)
    #expect(FileManager.default.fileExists(atPath: sheet))
}

@Test func testPeopleCanBeMerged() throws {
    let (env, target, source) = try twoPeople()
    let merged = try PeopleStore.merge(database: env.database, targetId: target, sourceIds: [source])
    #expect(try PeopleStore.list(database: env.database, limit: 100).arrayValue?.count == 1)
    #expect(merged["face_count"]?.intValue == 2)
    #expect(try PeopleStore.get(database: env.database, personId: target)["id"]?.intValue == target)
}

@Test func testMergeKeepsTargetName() throws {
    let (env, target, source) = try twoPeople()
    _ = try PeopleStore.name(database: env.database, personId: target, name: "Ирина")
    _ = try PeopleStore.name(database: env.database, personId: source, name: "Ира")
    let merged = try PeopleStore.merge(database: env.database, targetId: target, sourceIds: [source])
    #expect(merged["name"]?.stringValue == "Ирина")
}

@Test func testMergeIntoUnnamedTargetInheritsSourceName() throws {
    let (env, target, source) = try twoPeople()
    _ = try PeopleStore.name(database: env.database, personId: source, name: "Ирина")
    let merged = try PeopleStore.merge(database: env.database, targetId: target, sourceIds: [source])
    #expect(merged["name"]?.stringValue == "Ирина")
    #expect(merged["face_count"]?.intValue == 2)
}

@Test func testMergeRejectsPeopleFromDifferentModels() throws {
    let (env, target, source) = try twoPeople()
    let db = try Database.open(path: env.database)
    try db.execute("UPDATE people SET embedding_model = 'other-model' WHERE id = ?", [.integer(source)])
    do {
        _ = try PeopleStore.merge(database: env.database, targetId: target, sourceIds: [source])
        Issue.record("expected throw")
    } catch AilbumError.invalid(let message) {
        #expect(message.contains("разных моделей"))
    }
    #expect(try PeopleStore.list(database: env.database, limit: 100).arrayValue?.count == 2)
}

@Test func testDesktopBridgeMergesPersonIntoTarget() throws {
    let (env, target, source) = try twoPeople()
    _ = try PeopleStore.name(database: env.database, personId: target, name: "Ирина")
    let merged = try PeopleStore.merge(database: env.database, targetId: target, sourceIds: [source])
    #expect(merged["id"]?.intValue == target)
    #expect(merged["face_count"]?.intValue == 2)
    #expect(ids(try PeopleStore.list(database: env.database, limit: 100)) == [target])
}

@Test func testDesktopEditorCanReassignAndCreatePeople() throws {
    let (env, firstId, secondId) = try twoPeople()
    let faces = try PeopleStore.desktopFaces(database: env.database, personId: firstId)
    let faceId = try #require(faces["faces"]?[0]?["id"]?.intValue)

    _ = try PeopleStore.setFacePerson(database: env.database, faceId: faceId, personId: secondId)
    let people = try PeopleStore.desktopPeople(database: env.database)
    var counts: [Int: Int] = [:]
    for p in people["people"]?.arrayValue ?? [] {
        counts[p["id"]?.intValue ?? 0] = p["face_count"]?.intValue
    }
    #expect(counts[firstId] == 0)
    #expect(counts[secondId] == 2)

    _ = try PeopleStore.setFacePerson(database: env.database, faceId: faceId, personId: nil)
    #expect(try PeopleStore.desktopPeople(database: env.database)["unassigned_count"]?.intValue == 1)
    let created = try PeopleStore.createPersonFromFace(database: env.database, faceId: faceId, name: "New person")
    let createdId = try #require(created["id"]?.intValue)
    #expect(![firstId, secondId].contains(createdId))
    #expect(created["name"]?.stringValue == "New person")
    #expect(try PeopleStore.desktopPeople(database: env.database)["unassigned_count"]?.intValue == 0)
}
