import Testing

@testable import AilbumCore

private func prefPhoto(_ id: Int, _ regions: Region...) -> PhotoFacts {
    PhotoFacts(
        imageId: id, aspect: 1.5, unitKey: "image:\(id)", storyId: 1, takenAt: nil, rank: 0.5,
        selected: true, regions: regions)
}

private let prefFace = Region(bbox: Rect(x: 0.3, y: 0.2, w: 0.4, h: 0.5), weight: 1.0, hard: true, kind: "face")
private let prefSmallFace = Region(bbox: Rect(x: 0.3, y: 0.2, w: 0.05, h: 0.05), weight: 1.0, hard: true, kind: "face")
private let prefPerson = Region(bbox: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.6), weight: 0.6, hard: false, kind: "person")

@Suite struct LayoutPreferencesTests {
    @Test(arguments: [
        ("приоритет лицам и крупным планам", ["faces": 1.0, "closeups": 1.0]),
        ("лица, а не пейзажи", ["faces": 1.0, "landscapes": -1.0]),
        ("больше пейзажей, меньше людей", ["landscapes": 1.0, "faces": -1.0]),
        ("природа и виды", ["landscapes": 1.0]),
        ("что-нибудь красивое", [:]),
        ("", [:]),
        ("больше лиц", ["faces": 1.0]),
        ("Без ПЕЙЗАЖЕЙ. Больше детей", ["landscapes": -1.0, "faces": 1.0]),
        ("нет\nлиц, но пейзаж", ["faces": 1.0, "landscapes": 1.0]),
        (String(repeating: "а", count: 496) + " лиц", ["faces": 1.0]),
        (String(repeating: "а", count: 497) + " лиц", [:]),
    ] as [(String, [String: Double])])
    func layoutPreferencesParse(prompt: String, weights: [String: Double]) {
        #expect(Preferences.parse(prompt) == weights)
    }

    @Test func layoutPreferencesDescribeInAxisOrder() {
        #expect(
            Preferences.describe(["landscapes": -1.0, "faces": 1.0])
                == ["больше лиц", "меньше пейзажей"])
        #expect(Preferences.describe(["faces": 0.5]) == ["больше лиц"])
    }

    @Test func layoutPreferencesFeatures() {
        #expect(
            Preferences.features(prefPhoto(1, prefFace))
                == ["faces": 1.0, "closeups": 1.0, "landscapes": 0.0])
        #expect(Preferences.features(prefPhoto(2, prefSmallFace))["closeups"]! < 0.1)
        #expect(Preferences.features(prefPhoto(3, prefPerson))["faces"] == 0.5)
        #expect(Preferences.features(prefPhoto(4))["landscapes"] == 1.0)
    }

    @Test func layoutPreferencesApplyShiftsRank() {
        let portrait = prefPhoto(1, prefFace)
        let view = prefPhoto(2)
        let faces = Preferences.apply([portrait, view], ["faces": 1.0])
        #expect(faces[0].rank > faces[1].rank)
        #expect(faces[1].rank == 0.5)
        let views = Preferences.apply([portrait, view], ["landscapes": 1.0])
        #expect(views[1].rank > views[0].rank)
        #expect(Preferences.apply([portrait], [:]) == [portrait])
    }
}
