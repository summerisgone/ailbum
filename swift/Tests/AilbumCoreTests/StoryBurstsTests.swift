import Foundation
import Testing

@testable import AilbumCore

private func photo(
    _ id: String, _ at: String, _ lat: Double? = nil, _ lon: Double? = nil, people: Set<String> = [],
    scenes: [(String, Double)] = [], objects: [(String, Double)] = [], embedding: [Float]? = nil
) -> StoryPhoto {
    StoryPhoto(
        photoId: id, takenAt: at, gpsLatitude: lat, gpsLongitude: lon, people: people,
        scenes: scenes.map { TagRecord(label: $0.0, confidence: $0.1) }, objects: objects.map { TagRecord(label: $0.0, confidence: $0.1) }, embedding: embedding)
}

private func fixture() -> [StoryPhoto] {
    [
        photo("a", "2024-05-01T10:00:00", 10.0, 20.0, people: ["p1"], scenes: [("beach", 0.9), ("sky", 0.3)], objects: [("dog", 0.8)], embedding: [1, 0, 0.5, 0.25]),
        photo("b", "2024-05-01T10:00:30", 10.0, 20.1, scenes: [("beach", 0.7)], embedding: [0.75, 0.125, 0.5, 0.25]),
        photo("c", "2024-05-01T10:05:00", people: ["p1", "p2"], scenes: [("city", 0.6)], objects: [("car", 0.5), ("dog", 0.2)], embedding: [0, 1, 0, 0.5]),
        photo("d", "2024-05-01T10:05:20", 0.0, 0.0),
        photo("e", "2024-05-01T13:00:00", 50.0, 30.0, scenes: [("sky", -1.0)], embedding: [0.125, 0.25, 0.5]),
        photo("f", "2024-05-01T13:00:10", 50.0, 30.0, people: ["p2"], embedding: [0.25, 0.125, 0.5, 0.375]),
    ]
}

private func parsed(_ photos: [StoryPhoto]) -> [String: Date?] {
    Dictionary(uniqueKeysWithValues: photos.map { ($0.photoId, StoryBursts.parseTime($0.takenAt)) })
}

@Test func buildBurstsAndVectorsMatchPython() {
    let photos = fixture()
    var bursts = StoryBursts.build(photos, parsed: parsed(photos))
    #expect(bursts.map { $0.photos.map(\.photoId) } == [["a", "b"], ["c", "d"], ["e", "f"]])
    StoryBursts.attachVectors(&bursts)
    let first3: [[Double]] = [
        [0.8228676822111693, 0.05877626301508352, 0.47021010412066816],
        [0.0, 0.8749572785196141, 0.0],
        [0.3606678538669729, 0.18033392693348646, 0.7213357077339458],
    ]
    let image3: [[Double]] = [
        [0.8411784753765535, 0.06008417681261097, 0.48067341450088774],
        [0.0, 0.8944271909999159, 0.0],
        [0.3651483716701107, 0.18257418583505536, 0.7302967433402214],
    ]
    for (i, burst) in bursts.enumerated() {
        #expect(burst.vector?.count == 12)
        #expect(burst.imageVector?.count == 4)
        #expect(burst.semanticVector?.count == 5)
        #expect(burst.faceRate == 0.5)
        for k in 0..<3 {
            #expect(abs(burst.vector![k] - first3[i][k]) < 1e-9)
            #expect(abs(burst.imageVector![k] - image3[i][k]) < 1e-9)
        }
    }
    #expect(bursts[0].people == ["p1"])
    #expect(bursts[1].people == ["p1", "p2"])
    #expect(bursts[2].people == ["p2"])
}

@Test func burstWithoutContentInheritsClosest() {
    let photos = [photo("a", "2024-05-01T10:00:00", embedding: [1, 0]), photo("b", "2024-05-01T11:00:00")]
    var bursts = StoryBursts.build(photos, parsed: parsed(photos))
    StoryBursts.attachVectors(&bursts)
    #expect(bursts[1].vector == bursts[0].vector)
    #expect(bursts[1].imageVector == bursts[0].imageVector)
}

@Test func vectorDistanceCases() {
    #expect(StoryBursts.vectorDistance(nil, nil) == 0.0)
    #expect(StoryBursts.vectorDistance(nil, [1]) == 1.0)
    #expect(StoryBursts.vectorDistance([1], nil) == 1.0)
    #expect(StoryBursts.vectorDistance([1, 0], [0, 1]) == 1.0)
    #expect(abs(StoryBursts.vectorDistance([1, 1], [2, 0]) - 0.29289321881345254) < 1e-12)
    #expect(StoryBursts.vectorDistance([0, 0], [0, 0]) == 0.0)
    #expect(StoryBursts.vectorDistance([0, 0], [1, 1]) == 1.0)
}

@Test func distanceKmCases() {
    let p = photo("p", "x", 0.0, 1.0), q = photo("q", "x", 0.0, 2.0)
    #expect(abs(StoryBursts.distanceKm(p, q)! - 111.19492664455873) < 1e-9)
    #expect(abs(StoryBursts.distanceKm(photo("p", "x", 1.0, 0.0), photo("q", "x", 1.0, 1.0))! - 111.17799068882648) < 1e-9)
    let f = fixture()
    #expect(StoryBursts.distanceKm(f[0], f[2]) == nil)  // missing GPS
    #expect(StoryBursts.distanceKm(f[3], f[0]) == nil)  // 0,0 is missing
    #expect(abs(StoryBursts.distanceKm(f[0], f[1])! - 10.950562543608399) < 1e-9)
}

@Test func parseTimeCases() {
    let base = 1714557600.0  // 2024-05-01T10:00:00 UTC
    #expect(StoryBursts.parseTime("2024-05-01T10:00:00")?.timeIntervalSince1970 == base)
    #expect(StoryBursts.parseTime("2024-05-01T10:00:00+03:00")?.timeIntervalSince1970 == base)
    #expect(StoryBursts.parseTime("2024-05-01T10:00:00Z")?.timeIntervalSince1970 == base)
    #expect(StoryBursts.parseTime("2024-05-01 10:00:00.250")?.timeIntervalSince1970 == base + 0.25)
    #expect(StoryBursts.parseTime("2024-05-01")?.timeIntervalSince1970 == base - 36000)
    #expect(StoryBursts.parseTime("garbage") == nil)
    #expect(StoryBursts.parseTime("") == nil)
    #expect(StoryBursts.parseTime(nil) == nil)
    #expect(StoryBursts.formatTime(StoryBursts.parseTime("2024-05-01 10:00:00.250")!) == "2024-05-01T10:00:00.250000")
}
