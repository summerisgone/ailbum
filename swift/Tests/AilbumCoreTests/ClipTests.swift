import Foundation
import CoreML
import Testing
@testable import AilbumCore

private let tolerance = 1e-4

private func fakeText() -> ClipText {
    ClipText(
        model: "fake",
        logitScale: 1,
        aesthetic: [[2, 0], [0, 0]],
        scenes: [("a", [3, 0]), ("b", [1, 0]), ("c", [0, 0])],
        objects: [("x", [5, 0]), ("y", [0, 5])]
    )
}

@Suite(.serialized) struct ClipTests {
    @Test func recordExamples() {
        let r = Clip.record(embedding: [1, 0], text: fakeText(), threshold: 0.1, topK: 2)
        #expect(r.aestheticScore == 0.8808)
        #expect(r.model == "fake")
        #expect(r.scenes.map(\.label) == ["a", "b"])
        #expect(r.scenes.map(\.confidence) == [0.8438, 0.1142])
    }

    @Test func testRankThreshold() {
        let hi = Clip.record(embedding: [1, 0], text: fakeText(), threshold: 0.5, topK: 5)
        #expect(hi.scenes.map(\.label) == ["a"])
        let all = Clip.record(embedding: [1, 0], text: fakeText(), threshold: 0, topK: 5)
        #expect(all.scenes.map(\.label) == ["a", "b", "c"])
        let cut = Clip.record(embedding: [1, 0], text: fakeText(), threshold: 0, topK: 1)
        #expect(cut.scenes.count == 1)
        // objects ordering by probability desc
        let o = Clip.record(embedding: [0, 1], text: fakeText(), threshold: 0, topK: 5)
        #expect(o.objects.map(\.label) == ["y", "x"])
    }

    @Test func testEmbeddingNormalised() throws {
        Clip.embedder = { _ in [[3, 4]] }
        Clip.textOverride = fakeText()
        defer { Clip.embedder = nil; Clip.textOverride = nil }
        let img = RGBImage(width: 2, height: 2, pixels: [UInt8](repeating: 9, count: 12))
        let r = try Clip.analyze([img], threshold: 0, topK: 3)
        let e = try #require(r[0].embedding)
        #expect(abs(e[0] - 0.6) < 1e-6 && abs(e[1] - 0.8) < 1e-6)
        #expect(try Clip.analyze([], threshold: 0, topK: 3).isEmpty)
    }

    @Test func testClipTextDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = #"{"model":"m","logit_scale":100.0,"aesthetic":[[1,2],[3,4]],"scenes":[{"key":"s","embedding":[1,0]}],"objects":[{"key":"o","embedding":[0,1]}]}"#
        let url = dir.appendingPathComponent("ok.json")
        try good.write(to: url, atomically: true, encoding: .utf8)
        let t = try ClipText.load(url)
        #expect(t.model == "m" && t.logitScale == 100 && t.aesthetic == [[1, 2], [3, 4]])
        #expect(t.scenes[0].key == "s" && t.objects[0].embedding == [0, 1])
        let bad = dir.appendingPathComponent("bad.json")
        try #"{"model":"m"}"#.write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: AilbumError.self) { try ClipText.load(bad) }
        #expect(throws: AilbumError.self) { try ClipText.load(dir.appendingPathComponent("none.json")) }
    }

    @Test func testPreprocessParity() {
        let w = 300, h = 200
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                px[i] = UInt8((Double(x) * 255 / 299).rounded(.toNearestOrEven))
                px[i + 1] = UInt8((Double(y) * 255 / 199).rounded(.toNearestOrEven))
                px[i + 2] = UInt8((Double(x + y) * 255 / 498).rounded(.toNearestOrEven))
            }
        }
        let arr = Clip.preprocess(RGBImage(width: w, height: h, pixels: px))
        #expect(arr.shape.map(\.intValue) == [1, 3, 224, 224])
        let golden: [[Float]] = clipGolden
        let idx = [3, 34, 65, 96, 127, 158, 189, 220]
        var worst: Float = 0
        for c in 0..<3 {
            var k = 0
            for y in idx {
                for x in idx {
                    let v = arr[[0, c, y, x] as [NSNumber]].floatValue
                    worst = max(worst, abs(v - golden[c][k]))
                    k += 1
                }
            }
        }
        #expect(worst < 0.005, "worst \(worst)")
    }
    private func checksums(_ px: [UInt8]) -> (Int, Int) {
        var s = 0, t = 0
        for (i, v) in px.enumerated() { s += Int(v); t += (Int(v) * i) % 1009 }
        return (s, t)
    }

    @Test func testResizeMatchesPILGradient() {
        let w = 300, h = 200
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                px[i] = UInt8((Double(x) * 255 / 299).rounded(.toNearestOrEven))
                px[i + 1] = UInt8((Double(y) * 255 / 199).rounded(.toNearestOrEven))
                px[i + 2] = UInt8((Double(x + y) * 255 / 498).rounded(.toNearestOrEven))
            }
        }
        let r = Clip.resizeBicubic(px, w, h, 336, 224)
        #expect(r.count == 336 * 224 * 3)
        let (s, t) = checksums(r)
        #expect(s == 28788493)
        #expect(t == 113629268)
    }

    @Test func testResizeMatchesPILAstronaut() throws {
        let path = try #require(Bundle.module.url(forResource: "Fixtures/astronaut.png", withExtension: nil)).path
        let image = try ImageLoader.load(path: path)
        let r = Clip.resizeBicubic(image.pixels, image.width, image.height, 224, 224)
        let (s, t) = checksums(r)
        #expect(s == 17251227)
        #expect(t == 67324831)
    }
}


// CLIPImageProcessor golden (300x200 gradient), samples y,x in [3,34,...,220]
private let clipGolden: [[Float]] = [[-1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734, -1.1353, -0.7996, -0.4492, -0.0988, 0.2369, 0.5873, 0.9376, 1.2734], [-1.6921, -1.6921, -1.6921, -1.6921, -1.6921, -1.6921, -1.6921, -1.6921, -1.1668, -1.1668, -1.1668, -1.1668, -1.1668, -1.1668, -1.1668, -1.1668, -0.6415, -0.6415, -0.6415, -0.6415, -0.6415, -0.6415, -0.6415, -0.6415, -0.1012, -0.1012, -0.1012, -0.1012, -0.1012, -0.1012, -0.1012, -0.1012, 0.424, 0.424, 0.424, 0.424, 0.424, 0.424, 0.424, 0.424, 0.9643, 0.9643, 0.9643, 0.9643, 0.9643, 0.9643, 0.9643, 0.9643, 1.4896, 1.4896, 1.4896, 1.4896, 1.4896, 1.4896, 1.4896, 1.4896, 2.0149, 2.0149, 2.0149, 2.0149, 2.0149, 2.0149, 2.0149, 2.0149], [-1.0678, -0.883, -0.6697, -0.4706, -0.2715, -0.0724, 0.1409, 0.3399, -0.883, -0.6839, -0.4706, -0.2715, -0.0724, 0.1266, 0.3399, 0.5248, -0.6697, -0.4706, -0.2715, -0.0724, 0.1266, 0.3399, 0.539, 0.7381, -0.4706, -0.2715, -0.0724, 0.1409, 0.3399, 0.539, 0.7381, 0.9372, -0.2715, -0.0724, 0.1266, 0.3399, 0.5248, 0.7381, 0.9372, 1.1363, -0.0724, 0.1266, 0.3399, 0.539, 0.7381, 0.9372, 1.1363, 1.3354, 0.1409, 0.3399, 0.539, 0.7381, 0.9372, 1.1363, 1.3496, 1.5344, 0.3399, 0.5248, 0.7381, 0.9372, 1.1363, 1.3354, 1.5344, 1.7335]]
