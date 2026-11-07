import Foundation
import Testing
@testable import AilbumCore

@Test func testEncodeEmpty() {
    #expect(Vectors.encode([]) == nil)
}

@Test func testRoundTrip() throws {
    let encoded = try #require(Vectors.encode([3, 4]))
    let decoded = Vectors.decode(encoded, dimension: 2)
    #expect(abs(decoded[0] - 0.6) < 1e-6)
    #expect(abs(decoded[1] - 0.8) < 1e-6)
}

@Test func testLittleEndianBytes() throws {
    let encoded = try #require(Vectors.encode([1]))
    #expect(encoded == Data([0, 0, 128, 63]))
}

@Test func testDecodeZeroVector() throws {
    let encoded = try #require(Vectors.encode([0, 0, 0, 0]))
    #expect(Vectors.decode(encoded, dimension: 4) == [0, 0, 0, 0])
}

@Test func testClusterEmpty() {
    #expect(Vectors.clusterCosine([], threshold: 0.5) == [])
}

@Test func testClusterIdentical() {
    #expect(Vectors.clusterCosine([[1, 0], [2, 0], [0, 1]], threshold: 0.9) == [[0, 1], [2]])
}

@Test func testCompleteLinkTieLaterPairWins() {
    let features: [[Float]] = [[1, 0], [0.8, 0.6], [0.28, 0.96]]
    #expect(Vectors.clusterCosine(features, threshold: 0.75) == [[0], [1, 2]])
}

@Test func testUnionFindComponents() {
    var unionFind = UnionFind(size: 5)
    unionFind.union(0, 2)
    unionFind.union(3, 4)
    #expect(unionFind.components() == [[0, 2], [1], [3, 4]])
}

@Test func testDecodeShortBlobDoesNotTrap() {
    #expect(Vectors.decode(Data([1, 2, 3]), dimension: 2) == [])
    #expect(Vectors.decode(Data(), dimension: 4) == [])
    #expect(Vectors.decode(Data([0, 0, 128, 63]), dimension: 0) == [])
}
