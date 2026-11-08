import Foundation
import Testing

@testable import AilbumCore

private func photo(
    _ id: Int, unit: String? = nil, aspect: Double = 1.5, rank: Double = 0.5,
    selected: Bool = true, takenAt: String? = nil, regions: [Region] = []
) -> PhotoFacts {
    let minute = String(format: "%02d", id % 60)
    return PhotoFacts(
        imageId: id, aspect: aspect, unitKey: unit ?? "image:\(id)", storyId: 1,
        takenAt: takenAt ?? "2026-01-01T10:\(minute):00", rank: rank, selected: selected,
        regions: regions)
}

private func alloc(_ units: Int, _ spreads: Int, merged: Bool = false) -> Allocation {
    Allocation(storyIds: [1], unitCount: units, spreads: spreads, merged: merged)
}

private func params(_ spreads: Int = 2, low: Int = 3, high: Int = 3) -> LayoutParams {
    LayoutParams(orientation: "vertical", spreadCount: spreads, minPhotos: low, maxPhotos: high)
}

private typealias PlaceGold = (Int, Int, Int?, Double, Double, Double, Double, Double)

private struct G {
    var id: String
    var score: Double
    var warnings: [String]
    var placements: [PlaceGold]
    init(_ id: String, _ score: Double, _ warnings: [String], _ placements: [PlaceGold]) {
        self.id = id
        self.score = score
        self.warnings = warnings
        self.placements = placements
    }
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 }

private func matches(_ draft: SpreadDraft, _ gold: G) -> Bool {
    guard draft.templateId == gold.id, near(draft.score, gold.score),
        draft.warnings == gold.warnings, draft.placements.count == gold.placements.count
    else { return false }
    for (p, g) in zip(draft.placements, gold.placements) {
        guard p.cellIndex == g.0, p.imageId == g.1, p.replacedImageId == g.2, near(p.fit, g.3),
            near(p.crop.x, g.4), near(p.crop.y, g.5), near(p.crop.w, g.6), near(p.crop.h, g.7)
        else { return false }
    }
    return true
}

private func region(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ weight: Double,
    _ hard: Bool, _ kind: String) -> Region {
    Region(bbox: Rect(x: x, y: y, w: w, h: h), weight: weight, hard: hard, kind: kind)
}

private let pool: [PhotoFacts] = [
    PhotoFacts(imageId: 1, aspect: 1.5, unitKey: "image:1", storyId: 1, takenAt: "2026-01-01T10:01:00", rank: 0.9, selected: true, regions: [region(0.1, 0.2, 0.1, 0.15, 1.0, true, "face")]),
    PhotoFacts(imageId: 2, aspect: 0.7, unitKey: "image:2", storyId: 1, takenAt: "2026-01-01T10:02:00", rank: 0.4, selected: true, regions: []),
    PhotoFacts(imageId: 3, aspect: 1.6, unitKey: "cluster:1", storyId: 1, takenAt: "2026-01-01T10:03:00", rank: 0.6, selected: true, regions: [region(0.5, 0.4, 0.3, 0.3, 0.6, false, "object")]),
    PhotoFacts(imageId: 4, aspect: 0.75, unitKey: "cluster:1", storyId: 1, takenAt: "2026-01-01T10:03:30", rank: 0.55, selected: false, regions: []),
    PhotoFacts(imageId: 5, aspect: 1.0, unitKey: "image:5", storyId: 1, takenAt: "2026-01-01T10:05:00", rank: 0.2, selected: false, regions: [region(0.7, 0.1, 0.12, 0.2, 1.0, true, "face")]),
    PhotoFacts(imageId: 6, aspect: 1.33, unitKey: "cluster:2", storyId: 1, takenAt: "2026-01-01T10:06:00", rank: 0.8, selected: false, regions: []),
    PhotoFacts(imageId: 7, aspect: 0.66, unitKey: "cluster:2", storyId: 1, takenAt: "2026-01-01T10:06:10", rank: 0.3, selected: true, regions: [region(0.2, 0.5, 0.4, 0.3, 0.5, false, "object")]),
    PhotoFacts(imageId: 8, aspect: 1.78, unitKey: "image:8", storyId: 1, takenAt: nil, rank: 0.7, selected: true, regions: []),
]

private func checkGold(_ spreads: [SpreadDraft], _ gold: [(G, [G])]) {
    #expect(spreads.count == gold.count)
    for (s, g) in zip(spreads, gold) {
        #expect(matches(s, g.0))
        #expect(s.alternatives.count == g.1.count)
        for (a, ag) in zip(s.alternatives, g.1) { #expect(matches(a, ag)) }
    }
}

private enum Golden {
    static let goldA: [(G, [G])] = [
        (G("page_2h", 1.2649449492475298, [], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 3, nil, 0.9335482526422199, 0.11703020134228193, 0.0, 0.8829697986577181, 1.0), (2, 1, nil, 0.9601702530954195, 0.0, 0.0, 0.941834451901566, 1.0)]), [G("page_2h_m", 1.2649449492475298, [], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 3, nil, 0.9335482526422199, 0.11703020134228193, 0.0, 0.8829697986577181, 1.0), (2, 1, nil, 0.9601702530954195, 0.0, 0.0, 0.941834451901566, 1.0)]), G("pano_2", 1.131408877704832, [], [(0, 1, nil, 0.789029253062539, 0.0, 0.0, 1.0, 0.629225352112676), (1, 2, nil, 0.6681971496437055, 0.0, 0.30163895486935866, 1.0, 0.3967220902612827), (2, 3, nil, 0.9457355729814493, 0.0, 0.09320665083135382, 1.0, 0.9067933491686462)])]),
        (G("pano_2", 1.086193955747817, [], [(0, 8, nil, 0.8606744131455399, 0.0, 0.12665962441314554, 1.0, 0.7466807511737089), (1, 6, 7, 0.8645745843230405, 0.0, 0.12311401425178144, 1.0, 0.7537719714964372), (2, 5, nil, 0.7562494063617458, 0.0, 0.0, 1.0, 0.5667458432304039)]), [G("page_2h", 1.0313827296651787, [], [(0, 5, nil, 0.8257230770565775, 0.30528052805280526, 0.0, 0.6947194719471947, 1.0), (1, 8, nil, 0.8865243948420181, 0.10315964105271096, 0.0, 0.7936807178945781, 1.0), (2, 6, 7, 0.9677838479809977, 0.0, 0.029287410926365776, 1.0, 0.9414251781472684)]), G("page_2h_m", 1.0313827296651787, [], [(0, 5, nil, 0.8257230770565775, 0.30528052805280526, 0.0, 0.6947194719471947, 1.0), (1, 8, nil, 0.8865243948420181, 0.10315964105271096, 0.0, 0.7936807178945781, 1.0), (2, 6, 7, 0.9677838479809977, 0.0, 0.029287410926365776, 1.0, 0.9414251781472684)])])
    ]

    static let goldB: [(G, [G])] = [
        (G("page_1_inset", 1.1714467068842591, ["merged_stories"], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 1, nil, 0.6878264667049718, 0.0, 0.0, 0.4409857328145266, 1.0)]), [G("page_1_inset_m", 1.1714467068842591, ["merged_stories"], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 1, nil, 0.6878264667049718, 0.0, 0.0, 0.4409857328145266, 1.0)]), G("pages", 1.160397436442949, ["merged_stories"], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 1, nil, 0.6999438592131018, 0.0, 0.0, 0.46314631463146316, 1.0)])]),
        (G("pages", 0.9863420115755935, ["merged_stories"], [(0, 5, nil, 0.8257230770565775, 0.30528052805280526, 0.0, 0.6947194719471947, 1.0), (1, 4, 3, 0.9594609460946095, 0.03685368536853684, 0.0, 0.9262926292629263, 1.0)]), [G("page_1_inset", 0.9996319588243496, ["merged_stories"], [(0, 4, 3, 0.9594609460946095, 0.03685368536853684, 0.0, 0.9262926292629263, 1.0), (1, 5, nil, 0.8075447809443294, 0.33852140077821014, 0.0, 0.6614785992217899, 1.0)]), G("page_1_inset_m", 0.9996319588243496, ["merged_stories"], [(0, 4, 3, 0.9594609460946095, 0.03685368536853684, 0.0, 0.9262926292629263, 1.0), (1, 5, nil, 0.8075447809443294, 0.33852140077821014, 0.0, 0.6614785992217899, 1.0)])]),
        (G("page_1_inset", 1.106939909801596, ["merged_stories"], [(0, 7, nil, 0.9693113165313348, 0.0, 0.049976247030878884, 1.0, 0.9500237529691211), (1, 8, nil, 0.6543894548157216, 0.31419140471298035, 0.0, 0.37161719057403925, 1.0)]), [G("page_1_inset_m", 1.106939909801596, ["merged_stories"], [(0, 7, nil, 0.9693113165313348, 0.0, 0.049976247030878884, 1.0, 0.9500237529691211), (1, 8, nil, 0.6543894548157216, 0.31419140471298035, 0.0, 0.37161719057403925, 1.0)]), G("pages_inset", 1.0949802199968544, ["merged_stories"], [(0, 8, nil, 0.6605198172613903, 0.30861834794419063, 0.0, 0.38276330411161874, 1.0), (1, 7, nil, 0.9794406227323185, 0.0, 0.031290322580645125, 1.0, 0.9687096774193549)])])
    ]

    static let goldC: [(G, [G])] = [
        (G("page_cols_3_2", 1.2356704702463963, [], [(0, 1, nil, 0.9473689724509575, 0.0, 0.0, 0.91820987654321, 1.0), (1, 7, nil, 0.8553684931610901, 0.0, 0.25925531914893607, 1.0, 0.7407446808510639), (2, 2, nil, 0.8821010638297873, 0.0, 0.1071808510638298, 1.0, 0.7856382978723404), (3, 5, nil, 0.9611408837200108, 0.056872037914691975, 0.0, 0.943127962085308, 1.0), (4, 8, nil, 0.8702832951701369, 0.11792427711805742, 0.0, 0.7641514457638852, 1.0), (5, 3, nil, 0.933402999968127, 0.1172985781990522, 0.0, 0.8827014218009478, 1.0)]), [G("page_cols_3_2_m", 1.2356704702463963, [], [(0, 1, nil, 0.9473689724509575, 0.0, 0.0, 0.91820987654321, 1.0), (1, 7, nil, 0.8553684931610901, 0.0, 0.25925531914893607, 1.0, 0.7407446808510639), (2, 2, nil, 0.8821010638297873, 0.0, 0.1071808510638298, 1.0, 0.7856382978723404), (3, 5, nil, 0.9611408837200108, 0.056872037914691975, 0.0, 0.943127962085308, 1.0), (4, 8, nil, 0.8702832951701369, 0.11792427711805742, 0.0, 0.7641514457638852, 1.0), (5, 3, nil, 0.933402999968127, 0.1172985781990522, 0.0, 0.8827014218009478, 1.0)]), G("page_2_3", 1.1746631607751172, [], [(0, 1, nil, 0.9473689724509575, 0.0, 0.0, 0.91820987654321, 1.0), (1, 5, nil, 0.848168693705762, 0.0, 0.0, 1.0, 0.7351916376306621), (2, 3, nil, 0.9157614042777289, 0.1498815165876778, 0.0, 0.8501184834123222, 1.0), (3, 8, nil, 0.9132181208053691, 0.0, 0.07889261744966447, 1.0, 0.8422147651006711), (4, 7, nil, 0.5859137197908884, 0.0, 0.4984563758389261, 1.0, 0.28791946308724836), (5, 2, nil, 0.6321644295302014, 0.0, 0.3343959731543624, 1.0, 0.3312080536912751)])])
    ]

    static let goldV: [G] = [
        G("page_band", 1.206363219761801, [], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 3, nil, 0.9195241997574213, 0.0, 0.1267741935483871, 1.0, 0.8591397849462366), (2, 5, nil, 0.8283944469438853, 0.0, 0.0, 1.0, 0.6988950276243094), (3, 4, nil, 0.7382941988950277, 0.0, 0.23791436464088395, 1.0, 0.5241712707182321), (4, 1, nil, 0.8855424322617066, 0.0, 0.0, 1.0, 0.8054435483870968)]),
        G("page_band_m", 1.206363219761801, [], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 3, nil, 0.9195241997574213, 0.0, 0.1267741935483871, 1.0, 0.8591397849462366), (2, 5, nil, 0.8283944469438853, 0.0, 0.0, 1.0, 0.6988950276243094), (3, 4, nil, 0.7382941988950277, 0.0, 0.23791436464088395, 1.0, 0.5241712707182321), (4, 1, nil, 0.8855424322617066, 0.0, 0.0, 1.0, 0.8054435483870968)]),
        G("page_hero_3", 1.1918253444976248, [], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 1, nil, 0.844893455902139, 0.0, 0.0, 0.7292958911319123, 1.0), (2, 4, nil, 0.9120807712232806, 0.0799265716151995, 0.0, 0.840146856769601, 1.0), (3, 5, nil, 0.7764954680727374, 0.3952294073923912, 0.0, 0.6047705926076088, 1.0), (4, 3, nil, 0.6654466970294753, 0.4243268126224744, 0.0, 0.39381883911075083, 1.0)]),
        G("page_hero_3_m", 1.1918253444976248, [], [(0, 2, nil, 0.995851013672796, 0.0037718057520036985, 0.0, 0.9924563884959926, 1.0), (1, 1, nil, 0.844893455902139, 0.0, 0.0, 0.7292958911319123, 1.0), (2, 4, nil, 0.9120807712232806, 0.0799265716151995, 0.0, 0.840146856769601, 1.0), (3, 5, nil, 0.7764954680727374, 0.3952294073923912, 0.0, 0.6047705926076088, 1.0), (4, 3, nil, 0.6654466970294753, 0.4243268126224744, 0.0, 0.39381883911075083, 1.0)])
    ]
}

private func baseId(_ id: String) -> String {
    id.hasSuffix("_m") ? String(id.dropLast(2)) : id
}

@Suite struct LayoutComposerTests {
    @Test func composerSixUnitsTwoSpreads() throws {
        let group = try Composer.composeGroup(
            (1...6).map { photo($0) }, allocation: alloc(6, 2), params: params())
        #expect(group.spreads.count == 2)
        #expect(group.spreads.allSatisfy { $0.placements.count == 3 })
        #expect(group.unplaced == [])
    }

    @Test func composerEachUnitUsedOnce() throws {
        let group = try Composer.composeGroup(
            (1...9).map { photo($0) }, allocation: alloc(9, 3), params: params(3))
        let ids = group.spreads.flatMap { $0.placements.map(\.imageId) }
        #expect(ids.sorted() == Array(1...9))
    }

    @Test func composerTimeOrderBetweenSpreads() throws {
        let photos = (1...6).map {
            photo($0, takenAt: "2026-01-01T10:\(String(format: "%02d", 60 - $0)):00")
        }
        let group = try Composer.composeGroup(photos, allocation: alloc(6, 2), params: params())
        #expect(Set(group.spreads[0].placements.map(\.imageId)) == [4, 5, 6])
    }

    @Test func composerNoAdjacentRepeatWhenAlternativeExists() throws {
        let group = try Composer.composeGroup(
            (1...12).map { photo($0) }, allocation: alloc(12, 4), params: params(4))
        let ids = group.spreads.map { baseId($0.templateId) }
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func composerSimilarPicksFormatMatch() throws {
        var photos: [PhotoFacts] = []
        for (unit, base) in [(1, 1), (2, 3)] {
            photos.append(photo(base, unit: "cluster:\(unit)", aspect: 1.6, selected: true))
            photos.append(photo(base + 1, unit: "cluster:\(unit)", aspect: 0.7, selected: false))
        }
        let group = try Composer.composeGroup(
            photos, allocation: alloc(2, 1),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 2, maxPhotos: 2))
        let spread = group.spreads[0]
        #expect(spread.templateId.hasPrefix("pages"))
        #expect(Set(spread.placements.map(\.imageId)) == [2, 4])
        #expect(Set(spread.placements.map(\.replacedImageId)) == [1, 3])
    }

    @Test func composerSelectedBeatsEqualSibling() throws {
        let a = photo(1, unit: "cluster:1", selected: false)
        let b = photo(2, unit: "cluster:1", selected: true)
        let group = try Composer.composeGroup(
            [a, b], allocation: alloc(1, 1),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 1, maxPhotos: 1))
        let placement = group.spreads[0].placements[0]
        #expect(placement.imageId == 2)
        #expect(placement.replacedImageId == nil)
    }

    @Test func composerHeroGetsLargestCell() throws {
        let photos = [photo(1, rank: 0.1), photo(2, rank: 0.2), photo(3, rank: 1.0)]
        let group = try Composer.composeGroup(
            photos, allocation: alloc(3, 1),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 3, maxPhotos: 3))
        let spread = group.spreads[0]
        let template = try #require(
            try Templates.templatesFor("vertical", photoCount: 3).first { $0.id == spread.templateId })
        var areas: [Int: Double] = [:]
        for c in template.cells { areas[c.index] = c.rect.w * c.rect.h }
        let hero = try #require(spread.placements.first { $0.imageId == 3 })
        #expect(areas[hero.cellIndex] == areas.values.max())
    }

    @Test func composerCapacityOverflowGoesUnplaced() throws {
        let photos = (1...20).map { photo($0, rank: Double($0) / 100) }
        let group = try Composer.composeGroup(
            photos, allocation: alloc(20, 2),
            params: LayoutParams(orientation: "vertical", spreadCount: 2, minPhotos: 3, maxPhotos: 6))
        #expect(group.unplaced.count == 8)
        #expect(group.unplaced.allSatisfy { $0.objectValue?["reason"] == .string("capacity") })
        let ids = group.unplaced.compactMap { $0.objectValue?["image_id"]?.intValue }
        #expect(Set(ids) == Set(1...8))
        #expect(group.spreads.reduce(0) { $0 + $1.placements.count } == 12)
    }

    @Test func composerUnderfilledMarked() throws {
        let group = try Composer.composeGroup(
            [photo(1), photo(2)], allocation: alloc(2, 1),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 3, maxPhotos: 6))
        #expect(group.spreads[0].warnings.contains("underfilled"))
    }

    @Test func composerMergedStoriesWarning() throws {
        let group = try Composer.composeGroup(
            (1...3).map { photo($0) }, allocation: alloc(3, 1, merged: true), params: params(1))
        #expect(group.spreads[0].warnings.contains("merged_stories"))
    }

    @Test func composerDeterministic() throws {
        let photos = (1...9).map { photo($0, aspect: 0.7 + Double($0) / 10) }
        let first = try Composer.composeGroup(photos, allocation: alloc(9, 3), params: params(3))
        let second = try Composer.composeGroup(
            photos.reversed(), allocation: alloc(9, 3), params: params(3))
        #expect(first == second)
    }

    @Test func composerAlternativesSamePhotos() throws {
        let photos = (1...3).map { photo($0) }
        let spread = try Composer.composeGroup(photos, allocation: alloc(3, 1), params: params(1))
            .spreads[0]
        #expect((1...2).contains(spread.alternatives.count))
        let ids = spread.placements.map(\.imageId).sorted()
        for alt in spread.alternatives {
            #expect(alt.templateId != spread.templateId)
            #expect(alt.placements.map(\.imageId).sorted() == ids)
        }
    }

    @Test func composerBestVariantsLimitAndOrder() throws {
        let variants = try Composer.bestVariants(
            (1...4).map { photo($0) }, params: params(1), limit: 3)
        #expect(variants.count == 3)
        #expect(variants[0].score >= variants[1].score && variants[1].score >= variants[2].score)
        let one = try Composer.bestVariants([photo(1)], params: params(1), limit: 1)
        #expect(["full", "full_inset"].contains(one[0].templateId))
    }

    @Test func composerFaceNotCutInPlacements() throws {
        let face = Region(bbox: Rect(x: 0.05, y: 0.3, w: 0.1, h: 0.2), weight: 1.0, hard: true, kind: "face")
        let group = try Composer.composeGroup(
            [photo(1, regions: [face]), photo(2), photo(3)], allocation: alloc(3, 1),
            params: params(1))
        #expect(group.spreads[0].placements.allSatisfy { $0.warnings == [] })
    }

    @Test func composer100UnitsUnder5s() throws {
        let photos = (1...100).map { photo($0, aspect: 0.6 + Double($0 % 7) * 0.2) }
        let start = Date()
        let group = try Composer.composeGroup(
            photos, allocation: alloc(100, 20),
            params: LayoutParams(orientation: "vertical", spreadCount: 20, minPhotos: 3, maxPhotos: 6))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(group.spreads.reduce(0) { $0 + $1.placements.count } == 100)
    }

    @Test func composerSelectedMembersSplitWhenUnitsShort() throws {
        let photos = [
            photo(1, unit: "cluster:1"), photo(2, unit: "cluster:1"),
            photo(3, unit: "cluster:1", selected: false),
        ]
        let group = try Composer.composeGroup(
            photos, allocation: alloc(1, 1),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 2, maxPhotos: 3))
        let spread = group.spreads[0]
        #expect(!spread.warnings.contains("underfilled"))
        #expect(spread.placements.map(\.imageId).filter { [1, 2].contains($0) }.sorted() == [1, 2])
    }

    @Test func composerNoSplitWhenUnitsEnough() throws {
        let photos = [photo(1, unit: "cluster:1"), photo(2, unit: "cluster:1"), photo(3)]
        let group = try Composer.composeGroup(
            photos, allocation: alloc(2, 1),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 2, maxPhotos: 3))
        #expect(group.spreads[0].placements.count == 2)
    }

    @Test func composerNoStoryIdsGroup() throws {
        let group = try Composer.composeGroup(
            (1...3).map { photo($0) },
            allocation: Allocation(storyIds: [], unitCount: 3, spreads: 1, merged: false),
            params: params(1, low: 3, high: 3))
        #expect(group.spreads[0].storyIds == [])
    }

    @Test func composerGoldenTwoSpreads() throws {
        let group = try Composer.composeGroup(
            pool, allocation: Allocation(storyIds: [1], unitCount: 6, spreads: 2, merged: false),
            params: LayoutParams(orientation: "vertical", spreadCount: 2, minPhotos: 3, maxPhotos: 4))
        #expect(group.unplaced == [])
        checkGold(group.spreads, Golden.goldA)
    }

    @Test func composerGoldenMergedThreeSpreads() throws {
        let group = try Composer.composeGroup(
            pool, allocation: Allocation(storyIds: [1, 2], unitCount: 6, spreads: 3, merged: true),
            params: LayoutParams(orientation: "vertical", spreadCount: 3, minPhotos: 2, maxPhotos: 3))
        checkGold(group.spreads, Golden.goldB)
        #expect(group.spreads.allSatisfy { $0.storyIds == [1, 2] })
        #expect(group.spreads.allSatisfy { $0.alternatives.allSatisfy { $0.storyIds == [1, 2] } })
    }

    @Test func composerGoldenHorizontalOneSpread() throws {
        let group = try Composer.composeGroup(
            pool, allocation: Allocation(storyIds: [1], unitCount: 6, spreads: 1, merged: false),
            params: LayoutParams(orientation: "horizontal", spreadCount: 1, minPhotos: 5, maxPhotos: 8))
        checkGold(group.spreads, Golden.goldC)
    }

    @Test func composerGoldenBestVariants() throws {
        let variants = try Composer.bestVariants(
            Array(pool[0..<5]),
            params: LayoutParams(orientation: "vertical", spreadCount: 1, minPhotos: 1, maxPhotos: 5),
            limit: 4)
        #expect(variants.count == Golden.goldV.count)
        for (v, g) in zip(variants, Golden.goldV) { #expect(matches(v, g)) }
    }
}
