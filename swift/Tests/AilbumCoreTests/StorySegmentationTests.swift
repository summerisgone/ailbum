import Foundation
import Testing
@testable import AilbumCore

private let base = StoryBursts.parseTime("2024-05-01T08:00:00")!

private func mk(
    _ times: [Double], _ vecs: [[Double]], gps: [(Double, Double)]? = nil,
    img: [[Double]]? = nil, sem: [[Double]]? = nil, face: [Double]? = nil
) -> [StoryBurst] {
    times.indices.map { i in
        let t = base.addingTimeInterval(times[i] * 60)
        let photo = StoryPhoto(
            photoId: "p\(i)", takenAt: nil, gpsLatitude: gps?[i].0, gpsLongitude: gps?[i].1)
        return StoryBurst(
            photos: [photo], startedAt: t, endedAt: t, vector: vecs[i], imageVector: img?[i],
            semanticVector: sem?[i], faceRate: face?[i] ?? 0)
    }
}

private func pairs(_ r: [(Int, Int)]) -> [[Int]] { r.map { [$0.0, $0.1] } }

private let a: [Double] = [1, 0, 0]
private let b: [Double] = [0, 1, 0]

@Suite struct StorySegmentationTests {
    @Test func dayWithThreeHourGap() {
        let bs = mk([0, 2, 4, 184, 186, 188, 190, 192], Array(repeating: a, count: 3) + Array(repeating: b, count: 5))
        #expect(pairs(StorySegmentation.segment(bs, continuityMinutes: 360, maxDurationHours: 12)) == [[0, 3], [3, 8]])
    }

    @Test func longContinuousDaySplitsByDuration() {
        let bs = mk((0..<12).map { Double($0 * 90) }, Array(repeating: a, count: 12))
        #expect(pairs(StorySegmentation.segment(bs, continuityMinutes: 360, maxDurationHours: 12)) == [[0, 3], [3, 12]])
    }

    @Test func geographicJumpSplits() {
        let bs = mk([0, 20, 40, 60], Array(repeating: a, count: 4),
                    gps: [(55.75, 37.6), (55.75, 37.6), (59.9, 30.3), (59.9, 30.3)])
        #expect(pairs(StorySegmentation.segment(bs, continuityMinutes: 360, maxDurationHours: 12)) == [[0, 2], [2, 4]])
    }

    @Test func singleBurst() {
        let bs = mk([0], [a])
        #expect(pairs(StorySegmentation.segment(bs, continuityMinutes: 360, maxDurationHours: 12)) == [[0, 1]])
    }

    @Test func refineHiddenChangePoint() {
        let v1: [Double] = [1, 0.2, 0], v2: [Double] = [0.2, 1, 0]
        let bs = mk((0..<6).map { Double($0 * 10) }, [v1, v1, v1, v2, v2, v2],
                    img: [a, a, a, b, b, b], sem: [a, a, a, b, b, b], face: [0, 0, 0, 1, 1, 1])
        #expect(pairs(StorySegmentation.segment(bs, continuityMinutes: 360, maxDurationHours: 12)) == [[0, 3], [3, 6]])
        let r = StorySegmentation.refineChangePoints([(0, 6)], bs, Array(repeating: 10.0, count: 5))
        #expect(pairs(r) == [[0, 3], [3, 6]])
    }

    @Test func refineTieAndSizeGuards() {
        let pattern = [a, a, b, b, a, a, b, b]
        let bs = mk((0..<8).map { Double($0 * 10) }, pattern, img: pattern, sem: pattern, face: Array(repeating: 0, count: 8))
        let gaps = Array(repeating: 10.0, count: 7)
        #expect(pairs(StorySegmentation.refineChangePoints([(0, 8)], bs, gaps)) == [[0, 6], [6, 8]])
        #expect(pairs(StorySegmentation.segment(bs, continuityMinutes: 360, maxDurationHours: 12)) == [[0, 2], [2, 4], [4, 6], [6, 8]])
        #expect(pairs(StorySegmentation.refineChangePoints([(0, 3)], bs, gaps)) == [[0, 3]])
    }

    private func fixture() -> ([StoryPhoto], [String: Date?]) {
        let ph = [
            StoryPhoto(photoId: "f0", takenAt: "2024-05-01T10:00:00"),
            StoryPhoto(photoId: "f1", takenAt: "2024-05-01T10:05:00"),
            StoryPhoto(photoId: "f2", takenAt: "2024-05-01T14:30:00"),
            StoryPhoto(photoId: "f3", takenAt: "2024-05-01T16:00:00", people: ["x"]),
            StoryPhoto(photoId: "f4", takenAt: "2024-05-01T17:00:00", people: ["x"]),
            StoryPhoto(photoId: "f5", takenAt: "2024-05-01T17:10:00", gpsLatitude: 59.9, gpsLongitude: 30.3),
            StoryPhoto(photoId: "f6", takenAt: "2024-05-01T17:40:00", gpsLatitude: 55.75, gpsLongitude: 37.6),
        ]
        var parsed: [String: Date?] = [:]
        for p in ph { parsed[p.photoId] = StoryBursts.parseTime(p.takenAt) }
        return (ph, parsed)
    }

    private func ids(_ g: [[StoryPhoto]]) -> [[String]] { g.map { $0.map(\.photoId) } }

    @Test func fallbackGroupsWideGap() {
        let (ph, parsed) = fixture()
        let g = StorySegmentation.fallbackTimeGroups(ph, parsed: parsed, gapMinutes: 120, continuityMinutes: 360, maxDurationHours: 12)
        #expect(ids(g) == [["f0", "f1"], ["f2", "f3", "f4", "f5"], ["f6"]])
    }

    @Test func fallbackGroupsNarrowGap() {
        let (ph, parsed) = fixture()
        let g = StorySegmentation.fallbackTimeGroups(ph, parsed: parsed, gapMinutes: 30, continuityMinutes: 360, maxDurationHours: 6)
        #expect(ids(g) == [["f0", "f1"], ["f2"], ["f3", "f4", "f5"], ["f6"]])
    }
}
