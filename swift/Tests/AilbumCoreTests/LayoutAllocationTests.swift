import Testing

@testable import AilbumCore

private func g(_ ids: [Int], _ n: Int, _ start: String? = nil, _ end: String? = nil) -> StoryGroup {
    StoryGroup(storyIds: ids, unitCount: n, startedAt: start, endedAt: end)
}

private func allocate(_ groups: [StoryGroup], _ spreads: Int, _ minPhotos: Int, _ maxPhotos: Int) throws -> [Allocation] {
    try SpreadAllocation.allocateSpreads(groups, spreadCount: spreads, minPhotos: minPhotos, maxPhotos: maxPhotos)
}

@Test func allocationContractExample() throws {
    #expect(try allocate([g([1], 4)], 1, 1, 4) == [Allocation(storyIds: [1], unitCount: 4, spreads: 1, merged: false)])
}

@Test func allocationExamplesSplit() throws {
    #expect(try allocate([g([1], 12), g([2], 8)], 5, 3, 6) == [
        Allocation(storyIds: [1], unitCount: 12, spreads: 3, merged: false),
        Allocation(storyIds: [2], unitCount: 8, spreads: 2, merged: false),
    ])
}

@Test func allocationSmallStoryMerges() throws {
    #expect(try allocate([g([1], 2), g([2], 10)], 3, 3, 6) == [Allocation(storyIds: [1, 2], unitCount: 12, spreads: 3, merged: true)])
}

@Test func allocationMoreGroupsThanSpreadsMergesFirstSmallestPair() throws {
    #expect(try allocate([g([1], 5), g([2], 5), g([3], 5)], 2, 3, 6) == [
        Allocation(storyIds: [1, 2], unitCount: 10, spreads: 1, merged: true),
        Allocation(storyIds: [3], unitCount: 5, spreads: 1, merged: false),
    ])
}

@Test func allocationUntimedStoryMergesIntoPrevious() throws {
    let groups = [
        g([1], 6, "2024-01-01T10:00:00", "2024-01-01T11:00:00"),
        g([2], 6, "2024-01-01T11:05:00", "2024-01-01T12:00:00"),
        g([3], 1),
    ]
    let result = try allocate(groups, 3, 3, 6)
    #expect(result.map(\.storyIds) == [[1], [2, 3]])
    #expect(result[1].merged && result[1].unitCount == 7)
}

@Test func allocationUntimedFirstStoryMergesIntoNext() throws {
    let result = try allocate([g([1], 1), g([2], 6, "2024-01-01T10:00:00", nil)], 2, 3, 6)
    #expect(result.map(\.storyIds) == [[1, 2]])
}

@Test func allocationSmallStoryMergesWithNearestInTime() throws {
    let groups = [
        g([1], 6, "2024-01-01T08:00:00", "2024-01-01T09:00:00"),
        g([2], 1, "2024-01-03T08:00:00", "2024-01-03T08:30:00"),
        g([3], 6, "2024-01-03T09:00:00", "2024-01-03T10:00:00"),
    ]
    let result = try allocate(groups, 3, 3, 6)
    #expect(result.map(\.storyIds) == [[1], [2, 3]])
}

@Test func allocationSingleGroupGetsAllSpreads() throws {
    #expect(try allocate([g([7], 20)], 4, 3, 6) == [Allocation(storyIds: [7], unitCount: 20, spreads: 4, merged: false)])
}

@Test func allocationEmptyGroups() throws {
    #expect(try allocate([], 3, 3, 6) == [])
}

@Test func allocationInvalidSpreadCountThrows() {
    #expect(throws: AilbumError.invalid("spread_count must be at least 1")) {
        try allocate([g([1], 5)], 0, 3, 6)
    }
}

@Test func allocationMoreSpreadsThanUnitsPenalisedNotRaised() throws {
    let result = try allocate([g([1], 3), g([2], 3)], 4, 3, 6)
    #expect(result.map(\.spreads).reduce(0, +) == 4)
    #expect(result.map(\.spreads) == [2, 2])
}

@Test func allocationSumEqualsSpreadCountForManyShapes() throws {
    let values = [1, 2, 5, 9]
    for a in values { for b in values { for c in values {
        let sizes = [a, b, c]
        for spreads in [1, 2, 3, 5, 8] {
            let groups = sizes.enumerated().map { g([$0.offset], $0.element) }
            let result = try allocate(groups, spreads, 3, 6)
            #expect(result.map(\.spreads).reduce(0, +) == spreads)
            #expect(result.allSatisfy { $0.spreads >= 1 })
            #expect(result.map(\.unitCount).reduce(0, +) == sizes.reduce(0, +))
            #expect(result.flatMap(\.storyIds) == [0, 1, 2])
        }
    }}}
}
