import Testing
@testable import AilbumCore

@Suite struct LayoutTypesTests {
    @Test func layoutParamsDefaults() {
        let p = LayoutParams(orientation: "vertical", spreadCount: 10, minPhotos: 1, maxPhotos: 4)
        #expect(p.assistant == "auto")
        #expect(p.prompt == "")
    }

    @Test func spreadDraftDefaults() {
        let s = SpreadDraft(templateId: "t", storyIds: [1], placements: [], score: 0)
        #expect(s.warnings == [])
        #expect(s.alternatives == [])
        #expect(s.assistantReason == nil)
    }

    @Test func rectEquality() {
        #expect(Rect(x: 0, y: 0, w: 1, h: 1) == Rect(x: 0, y: 0, w: 1, h: 1))
        #expect(Rect(x: 0, y: 0, w: 1, h: 1) != Rect(x: 0, y: 0, w: 1, h: 2))
    }

    @Test func nestedAlternativesEquality() {
        let r = Rect(x: 0, y: 0, w: 1, h: 1)
        let p = PlacementDraft(cellIndex: 0, imageId: 5, crop: r, fit: 1, warnings: [], replacedImageId: nil)
        let inner = SpreadDraft(templateId: "a", storyIds: [1], placements: [p], score: 1)
        let outer = SpreadDraft(templateId: "b", storyIds: [1], placements: [], score: 2, alternatives: [inner])
        #expect(outer.alternatives.first?.placements.first?.imageId == 5)
        #expect(outer != inner)
    }
}
