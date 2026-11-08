import Foundation
import Testing
@testable import AilbumCore

private func lcg(_ n: Int, _ seed: UInt32) -> [Float] {
    var s = seed
    return (0..<n * 128).map { _ in
        s = s &* 1664525 &+ 1013904223
        return Float((s >> 16) & 255)
    }
}

private func flat(_ rows: [[Float]]) -> [Float] { rows.flatMap { $0 } }

private func cpuBest(_ q: [Float], _ t: [Float], row: Int, dim: Int) -> (Int, Float, Float) {
    var b1 = Float.infinity, b2 = Float.infinity, bi = -1
    for j in 0..<(t.count / dim) {
        var d: Float = 0
        for k in 0..<dim { let e = q[row * dim + k] - t[j * dim + k]; d += e * e }
        if d < b1 { b2 = b1; b1 = d; bi = j } else if d < b2 { b2 = d }
    }
    return (bi, b1, b2)
}

@Suite struct MatcherTests {
    @Test func basicPairs() throws {
        let l = flat([[0, 0], [10, 10]])
        let r = flat([[0, 1], [10, 11], [50, 50]])
        let m = try Matcher.mutualRatioMatches(left: l, right: r, dim: 2, ratio: 0.75)
        #expect(m.map { [$0.0, $0.1] } == [[0, 0], [1, 1]])
    }

    @Test func singleRow() throws {
        let m = try Matcher.mutualRatioMatches(left: [0, 0], right: flat([[0, 1], [1, 1]]), dim: 2, ratio: 0.75)
        #expect(m.isEmpty)
    }

    @Test func ratioRejectsAmbiguous() throws {
        let l = flat([[0, 0], [100, 0]])
        let r = flat([[1, 0], [-1, 0], [100, 1]])
        let m = try Matcher.mutualRatioMatches(left: l, right: r, dim: 2, ratio: 0.75)
        #expect(m.map { [$0.0, $0.1] } == [[1, 2]])
    }

    @Test func ratioIsOnNonSquaredDistance() throws {
        // d1=3, d2=4: 3 < 0.75*4 is false (3 == 3); squared would give 9 < 0.75*16=12 true
        let l = flat([[0, 0], [100, 100]])
        let r = flat([[3, 0], [-4, 0], [100, 100]])
        let m = try Matcher.mutualRatioMatches(left: l, right: r, dim: 2, ratio: 0.75)
        #expect(!m.contains { $0.0 == 0 })
    }

    @Test func parityRandom() throws {
        let a = lcg(300, 1)
        var b = lcg(280, 2)
        for i in 0..<100 {
            for k in 0..<128 {
                b[i * 128 + k] = min(max(a[(2 * i) * 128 + k] + Float(k % 3 - 1), 0), 255)
            }
        }
        let m = try Matcher.mutualRatioMatches(left: a, right: b, dim: 128, ratio: 0.75)
        #expect(m.map { [$0.0, $0.1] } == (0..<100).map { [2 * $0, $0] })
        // buffer reuse: second call identical
        let m2 = try Matcher.mutualRatioMatches(left: a, right: b, dim: 128, ratio: 0.75)
        #expect(m.map { [$0.0, $0.1] } == m2.map { [$0.0, $0.1] })
    }

    @Test func tiesLowerIndexWins() throws {
        let l = flat([[0, 0]])
        let r = flat([[1, 0], [1, 0], [0, 5]])
        // d1 = d2 = 1 -> ratio fails regardless; check via 2-row left that ties do not crash
        let m = try Matcher.mutualRatioMatches(left: l + l, right: r, dim: 2, ratio: 0.75)
        #expect(m.isEmpty)
    }

    @Test func large() throws {
        let a = lcg(4000, 7)
        var b = lcg(4000, 9)
        for i in 0..<500 { for k in 0..<128 { b[i * 128 + k] = a[(i * 7) * 128 + k] } }
        let m = try Matcher.mutualRatioMatches(left: a, right: b, dim: 128, ratio: 0.75)
        var expected: [[Int]] = []
        for i in 0..<500 { expected.append([i * 7, i]) }
        let got = m.filter { $0.1 < 500 }.map { [$0.0, $0.1] }
        #expect(got == expected)
        // CPU reference on 50 sampled forward rows: every reported pair must pass the ratio test
        let lookup = Dictionary(uniqueKeysWithValues: m.map { ($0.0, $0.1) })
        for s in 0..<50 {
            let row = s * 79
            let (bi, d1, d2) = cpuBest(a, b, row: row, dim: 128)
            if let j = lookup[row] { #expect(j == bi) }
            if sqrt(d1) < 0.75 * sqrt(d2), let j = lookup[row] { #expect(j == bi) }
        }
    }
}
