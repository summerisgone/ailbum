import Foundation
import Testing
@testable import AilbumCore

private struct GObject: Decodable { var label: String; var score: Double; var bbox: [Double] }
private struct GTag: Decodable { var label: String; var confidence: Double }
private struct GSemantic: Decodable {
    var aesthetic_score: Double
    var scenes: [GTag]
    var embedding: [Float]
}
private struct Golden: Decodable { var objects: [GObject]; var semantic: GSemantic }

private func fixture(_ name: String) throws -> String {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)).path
}

private func golden() throws -> Golden {
    try JSONDecoder().decode(Golden.self, from: Data(contentsOf: URL(fileURLWithPath: fixture("objects_clip_golden.json"))))
}

private func iou(_ a: [Double], _ b: SIMD4<Float>) -> Double {
    let (bx, by, bw, bh) = (Double(b[0]), Double(b[1]), Double(b[2]), Double(b[3]))
    let iw = min(a[0] + a[2], bx + bw) - max(a[0], bx)
    let ih = min(a[1] + a[3], by + bh) - max(a[1], by)
    guard iw > 0, ih > 0 else { return 0 }
    let inter = iw * ih
    return inter / (a[2] * a[3] + bw * bh - inter)
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for (x, y) in zip(a, b) { d += Double(x * y); na += Double(x * x); nb += Double(y * y) }
    return d / (na.squareRoot() * nb.squareRoot())
}

@Suite struct ObjectsClipParityTests {
    @Test(.enabled(if: ModelStore.available("yolox"))) func testObjectsParity() throws {
        let g = try golden()
        let image = try ImageLoader.load(path: fixture("astronaut.png"))
        let s = try YOLOX.detect(image)
        #expect(Set(s.map(\.label)) == Set(g.objects.map(\.label)))
        #expect(s.count == g.objects.count)
        for (a, b) in zip(g.objects, s) {
            print("PARITY object", a.label, a.score, b.score, iou(a.bbox, b.bbox))
            #expect(abs(a.score - Double(b.score)) <= 0.05)
            #expect(iou(a.bbox, b.bbox) >= 0.85)
        }
    }

    @Test(.enabled(if: ModelStore.available("clip_vision"))) func testClipParity() throws {
        let g = try golden().semantic
        let image = try ImageLoader.load(path: fixture("astronaut.png"))
        let r = try Clip.analyze([image], threshold: 0.15, topK: 3)[0]
        let e = try #require(r.embedding)
        let cos = cosine(e, g.embedding)
        let diff = abs((r.aestheticScore ?? -1) - g.aesthetic_score)
        print("PARITY clip cosine", cos, "aesthetic", r.aestheticScore as Any, g.aesthetic_score, "scenes", r.scenes, g.scenes)
        #expect(cos >= 0.995)
        #expect(diff <= 0.02)
        #expect(r.scenes.first?.label == g.scenes.first?.label)
    }

    @Test(.enabled(if: ModelStore.available("clip_vision") && ModelStore.available("yolox")))
    func testAnalyzeImageCLI() throws {
        let exe = try #require(Self.executable())
        let p = Process()
        p.executableURL = exe
        p.arguments = ["analyze-image", try fixture("astronaut.png")]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 1)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(obj["faces"] is [Any])
        #expect(obj["objects"] is [Any])
        #expect(obj["semantic"] is [String: Any])
    }

    private static func executable() -> URL? {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            dir.deleteLastPathComponent()
            let debug = dir.appendingPathComponent(".build/debug/ailbum-swift")
            if FileManager.default.isExecutableFile(atPath: debug.path) { return debug }
        }
        return nil
    }
}
