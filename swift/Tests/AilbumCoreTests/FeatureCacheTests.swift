import Foundation
import Testing
@testable import AilbumCore

private func tempDir() -> String {
    let dir = NSTemporaryDirectory() + "fc-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func sample() -> (PhotoRecord, PhotoFeatures) {
    let faces = [
        FaceRecord(faceId: "old-1", bbox: SIMD4(1, 2, 30, 40), confidence: 0.91, embedding: [0.25, -0.5, 0.125],
                   eyes: EyeStateRecord(left: "open", right: "closed", leftOpenProbability: 0.9,
                                        rightOpenProbability: 0.1, bothOpen: false),
                   expression: ExpressionRecord(label: "happy", confidence: 0.8, smileProbability: 0.7,
                                                scores: ["happy": 0.7, "neutral": 0.3])),
        FaceRecord(faceId: "old-2", bbox: SIMD4(5, 6, 70, 80), confidence: 0.5, embedding: [1, 2, 3]),
    ]
    let record = PhotoRecord(
        photoId: "orig", path: "/orig.jpg", width: 640, height: 480, takenAt: "2024-01-01T00:00:00",
        sharpness: 120.5, exposure: 0.8, quality: 0.66, isBlurry: false,
        composition: CompositionRecord(ruleOfThirds: 0.1, frameOccupancy: 0.2, negativeSpace: 0.3, cropRisk: 0.4,
                                       score: 0.5, mainSubject: SubjectRecord(bbox: SIMD4(0.1, 0.2, 0.3, 0.4),
                                                                              center: SIMD2(0.2, 0.3), source: "faces")),
        color: ColorRecord(balance: 0.5, harmony: 0.6, meanSaturation: 0.7),
        semantics: SemanticRecord(aestheticScore: 5.5, model: "clip",
                                  scenes: [TagRecord(label: "beach", confidence: 0.9)],
                                  objects: [TagRecord(label: "dog", confidence: 0.4)], embedding: [0.5, 0.25]),
        faces: faces)
    let features = PhotoFeatures(
        phash: (0..<64).map { $0 % 3 == 0 }, histogram: (0..<8).map { Float($0) / 8 },
        geometric: GeometricFeatures(keypoints: [SIMD2(1.5, 2.5), SIMD2(3, 4)], descriptors: (0..<256).map { Float($0) * 0.5 },
                                     width: 320, height: 240))
    return (record, features)
}

@Test func testSignatureMatchesPython() {
    let sig = FeatureCache.signature(["max_image_side": 1600, "semantic_threshold": 0.15, "face_backend": "dnn"])
    #expect(sig == "31bc0ca0291b1e2e7033")
}

@Test func testFeatureCacheRoundTrip() throws {
    let cache = FeatureCache(root: tempDir(), signature: "sig")
    let (record, features) = sample()
    cache.store(sha256: "abc", record: record, features: features)
    let loaded = try #require(cache.load(sha256: "abc", photoId: "p9", path: "/x.jpg", takenAt: nil, sharpnessThreshold: 200))
    let (r, f) = loaded
    #expect(r.photoId == "p9" && r.path == "/x.jpg" && r.takenAt == nil)
    #expect(r.isBlurry)
    #expect(r.width == 640 && r.height == 480 && r.sharpness == 120.5 && r.exposure == 0.8 && r.quality == 0.66)
    #expect(r.composition == record.composition)
    #expect(r.color == record.color)
    #expect(r.semantics?.scenes == record.semantics?.scenes && r.semantics?.embedding == [0.5, 0.25])
    #expect(r.semantics?.aestheticScore == 5.5 && r.semantics?.model == "clip")
    #expect(r.faces.count == 2)
    #expect(r.faces[0].faceId == "p9-face-01" && r.faces[1].faceId == "p9-face-02")
    #expect(r.faces[0].eyes == record.faces[0].eyes && r.faces[0].expression == record.faces[0].expression)
    #expect(r.faces[0].embedding == [0.25, -0.5, 0.125] && r.faces[1].eyes == nil)
    #expect(r.faces[0].bbox == SIMD4(1, 2, 30, 40))
    #expect(f.phash == features.phash && f.histogram == features.histogram)
    #expect(f.geometric?.keypoints == features.geometric?.keypoints)
    #expect(f.geometric?.descriptors == features.geometric?.descriptors)
    #expect(f.geometric?.width == 320 && f.geometric?.height == 240)
    #expect(cache.hits == 1 && cache.writes == 1 && cache.misses == 0)
    let again = try #require(cache.load(sha256: "abc", photoId: "p", path: "/x.jpg", takenAt: "t", sharpnessThreshold: 50))
    #expect(!again.0.isBlurry && again.0.takenAt == "t")
    let leftover = try FileManager.default.contentsOfDirectory(atPath: cache.directory)
    #expect(leftover == ["abc.swcache"])
}

@Test func testMissCounts() {
    let root = tempDir()
    let cache = FeatureCache(root: root, signature: "sig")
    #expect(cache.load(sha256: "s", photoId: "p", path: "/x.jpg", takenAt: nil, sharpnessThreshold: 80) == nil)
    #expect(cache.misses == 1 && cache.hits == 0)
    #expect(cache.stats() == ["enabled": true, "directory": .string(root + "/sig"), "hits": 0, "misses": 1,
                              "writes": 0, "error": nil])
}

@Test func testCorruptFileIsMiss() throws {
    let cache = FeatureCache(root: tempDir(), signature: "sig")
    let (record, features) = sample()
    cache.store(sha256: "ok", record: record, features: features)
    let good = try Data(contentsOf: URL(fileURLWithPath: cache.directory + "/ok.swcache"))
    let cases: [Data] = [Data("garbage".utf8), Data(), good.prefix(good.count - 3), Data([255, 255, 255, 255, 1])]
    for (i, bad) in cases.enumerated() {
        try bad.write(to: URL(fileURLWithPath: cache.directory + "/bad\(i).swcache"))
        #expect(cache.load(sha256: "bad\(i)", photoId: "p", path: "/x", takenAt: nil, sharpnessThreshold: 1) == nil)
    }
    #expect(cache.misses == cases.count && cache.hits == 0)
}

@Test func testUnwritableRootDisables() throws {
    let root = tempDir() + "/file"
    try Data("x".utf8).write(to: URL(fileURLWithPath: root))
    let cache = FeatureCache(root: root, signature: "sig")
    #expect(!cache.available)
    let (record, features) = sample()
    cache.store(sha256: "a", record: record, features: features)
    #expect(cache.load(sha256: "a", photoId: "p", path: "/x", takenAt: nil, sharpnessThreshold: 1) == nil)
    let stats = cache.stats()
    #expect(stats["enabled"] == false && stats["writes"] == 0 && stats["misses"] == 0)
    #expect(stats["error"]?.stringValue?.isEmpty == false)
}
