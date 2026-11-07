import Foundation
import Testing
@testable import AilbumCore

private struct GoldenKP: Decodable {
    let x: Float, y: Float, size: Float, angle: Float, response: Float
    let descriptor: [Float]
}
private struct Golden: Decodable {
    let count: Int
    let top: [GoldenKP]
    let score_ab: Double
    let score_ac: Double
}

private func fixture(_ name: String, _ ext: String) throws -> String {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext)).path
}

private func loadGolden() throws -> Golden {
    try JSONDecoder().decode(Golden.self, from: Data(contentsOf: URL(fileURLWithPath: fixture("sift_golden", "json"))))
}

private func features(_ name: String) throws -> GeometricFeatures {
    try SIFT.extract(ImageLoader.load(path: fixture(name, "png")))
}

private func pipeline(_ name: String) throws -> ([SiftKeypoint], [Float]) {
    let image = try ImageLoader.load(path: fixture(name, "png"))
    let space = try ScaleSpace.build(ScaleSpace.grayFloat(image), layers: 3, sigma: 1.6)
    let kps = SiftDetector.retainBest(
        SiftDetector.assignOrientations(SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10), space: space),
        maxFeatures: 4000)
    return (kps, SiftDescriptor.compute(kps, space: space))
}

/// (swift index, golden keypoint): within 1.5 px, size within 20%, nearest angle
private func matchedPairs(_ kps: [SiftKeypoint], _ g: Golden) -> [(Int, GoldenKP)] {
    var out: [(Int, GoldenKP)] = []
    for k in g.top {
        var best = -1
        var bestA: Float = 360
        for (i, p) in kps.enumerated() {
            guard hypot(p.x - k.x, p.y - k.y) <= 1.5, abs(p.size - k.size) <= 0.2 * k.size else { continue }
            var da = abs(p.angle - k.angle)
            da = min(da, 360 - da)
            if da < bestA { bestA = da; best = i }
        }
        if best >= 0 { out.append((best, k)) }
    }
    return out
}

@Test func testKeypointParity() throws {
    let g = try loadGolden()
    let (kps, _) = try pipeline("sift_a")
    let ratio = Double(kps.count) / Double(g.count)
    print("T8 count swift=\(kps.count) cv2=\(g.count) ratio=\(ratio)")
    #expect(ratio >= 0.8 && ratio <= 1.2)
    let frac = Double(matchedPairs(kps, g).count) / Double(g.top.count)
    print("T8 matched within 1.5px: \(frac)")
    #expect(frac >= 0.75)
}

@Test func testDescriptorParity() throws {
    let g = try loadGolden()
    let (kps, desc) = try pipeline("sift_a")
    var cosines: [Double] = []
    for (i, k) in matchedPairs(kps, g) {
        let d = desc[(i * 128)..<((i + 1) * 128)]
        var dot = 0.0, na = 0.0, nb = 0.0
        for (a, b) in zip(d, k.descriptor) { dot += Double(a * b); na += Double(a * a); nb += Double(b * b) }
        cosines.append(dot / max((na * nb).squareRoot(), 1e-12))
    }
    cosines.sort()
    let median = cosines.isEmpty ? 0 : cosines[cosines.count / 2]
    print("T8 median descriptor cosine: \(median) over \(cosines.count)")
    #expect(median >= 0.9)
}

@Test func testSceneParity() throws {
    let g = try loadGolden()
    let s = try Similarity.geometric(features("sift_a"), features("sift_b"))
    print("T8 score a/b swift=\(s.score) cv2=\(g.score_ab)")
    #expect(abs(s.score - g.score_ab) <= 0.1)
    #expect(s.score >= 0.55)
}

@Test func testUnrelated() throws {
    let s = try Similarity.geometric(features("sift_a"), features("sift_c"))
    print("T8 score a/c swift=\(s.score)")
    #expect(s.score < 0.1)
}

@Test func testCompareCLI() throws {
    var pkg = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { pkg.deleteLastPathComponent() }
    func swiftRun(_ args: [String]) throws -> String {
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        q.arguments = ["swift", "build", "--package-path", pkg.path] + args
        let out = Pipe()
        q.standardOutput = out
        q.standardError = Pipe()
        try q.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        q.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let binDir = try swiftRun(["--show-bin-path"])
    let exe = URL(fileURLWithPath: binDir + "/ailbum-swift")
    if !FileManager.default.isExecutableFile(atPath: exe.path) {
        _ = try swiftRun(["--product", "ailbum-swift"])
    }
    #expect(FileManager.default.isExecutableFile(atPath: exe.path))
    let p = Process()
    p.executableURL = exe
    p.arguments = ["compare", try fixture("sift_a", "png"), try fixture("sift_b", "png")]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.split(separator: "\n").count == 1)
    let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(obj.keys) == ["score", "mutual_matches", "inliers", "inlier_ratio", "coverage_left", "coverage_right"])
}
