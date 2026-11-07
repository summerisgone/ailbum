import CoreML
import Foundation

public struct ClipText {
    public var model: String
    public var logitScale: Double
    public var aesthetic: [[Float]]
    public var scenes: [(key: String, embedding: [Float])]
    public var objects: [(key: String, embedding: [Float])]

    public init(
        model: String, logitScale: Double, aesthetic: [[Float]],
        scenes: [(key: String, embedding: [Float])], objects: [(key: String, embedding: [Float])]
    ) {
        self.model = model
        self.logitScale = logitScale
        self.aesthetic = aesthetic
        self.scenes = scenes
        self.objects = objects
    }

    private struct Entry: Decodable { var key: String; var embedding: [Float] }
    private struct Raw: Decodable {
        var model: String
        var logit_scale: Double
        var aesthetic: [[Float]]
        var scenes: [Entry]
        var objects: [Entry]
    }

    public static func load(_ url: URL) throws -> ClipText {
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: Data(contentsOf: url))
            return ClipText(
                model: raw.model, logitScale: raw.logit_scale, aesthetic: raw.aesthetic,
                scenes: raw.scenes.map { ($0.key, $0.embedding) },
                objects: raw.objects.map { ($0.key, $0.embedding) })
        } catch {
            throw AilbumError.decode("clip_text \(url.path): \(error)")
        }
    }
}

public enum Clip {
    static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    static let std: [Float] = [0.26862954, 0.26130258, 0.27577711]

    /// Test seam: replaces the CoreML image encoder (returns one embedding per image).
    nonisolated(unsafe) static var embedder: (([RGBImage]) throws -> [[Float]])?
    /// Test seam: replaces clip_text.json.
    nonisolated(unsafe) static var textOverride: ClipText?

    /// Resize shortest side to 224 (PIL BICUBIC port), centre crop, normalise; shape 1x3x224x224.
    public static func preprocess(_ image: RGBImage) -> MLMultiArray {
        let size = 224
        let short = min(image.width, image.height)
        let newW = image.width <= image.height ? size : max(size, Int(Double(size) * Double(image.width) / Double(short)))
        let newH = image.width <= image.height ? max(size, Int(Double(size) * Double(image.height) / Double(short))) : size
        let resized = resizeBicubic(image.pixels, image.width, image.height, newW, newH)
        let out = try! MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let ptr = out.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        let ox = (newW - size) / 2, oy = (newH - size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let s = ((y + oy) * newW + x + ox) * 3
                for c in 0..<3 {
                    ptr[c * size * size + y * size + x] = (Float(resized[s + c]) / 255 - mean[c]) / std[c]
                }
            }
        }
        return out
    }

    private static func bicubic(_ xin: Double) -> Double {
        let a = -0.5, x = abs(xin)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// Port of Pillow ImagingResample (BICUBIC, 8-bit fixed point, horizontal then vertical). RGB interleaved.
    static func resizeBicubic(_ src: [UInt8], _ w: Int, _ h: Int, _ newW: Int, _ newH: Int) -> [UInt8] {
        func coeffs(_ inSize: Int, _ outSize: Int) -> (bounds: [(Int, Int)], k: [[Int32]]) {
            let scale = Double(inSize) / Double(outSize)
            let fscale = max(scale, 1.0)
            let support = 2.0 * fscale
            var bounds: [(Int, Int)] = [], ks: [[Int32]] = []
            for xx in 0..<outSize {
                let center = (Double(xx) + 0.5) * scale
                let ss = 1.0 / fscale
                let xmin = max(Int(center - support + 0.5), 0)
                let xmax = min(Int(center + support + 0.5), inSize) - xmin
                var k = (0..<xmax).map { bicubic((Double($0 + xmin) - center + 0.5) * ss) }
                let total = k.reduce(0, +)
                if total != 0 { k = k.map { $0 / total } }
                bounds.append((xmin, xmax))
                ks.append(k.map { Int32($0 < 0 ? -0.5 + $0 * 4194304.0 : 0.5 + $0 * 4194304.0) })
            }
            return (bounds, ks)
        }
        func clip8(_ v: Int32) -> UInt8 { UInt8(max(0, min(255, v >> 22))) }
        var cur = src, cw = w, ch = h
        if newW != w {
            let (b, k) = coeffs(w, newW)
            var out = [UInt8](repeating: 0, count: newW * ch * 3)
            for y in 0..<ch {
                for x in 0..<newW {
                    let (xmin, n) = b[x]
                    for c in 0..<3 {
                        var acc: Int32 = 1 << 21
                        for i in 0..<n { acc += Int32(cur[(y * cw + xmin + i) * 3 + c]) * k[x][i] }
                        out[(y * newW + x) * 3 + c] = clip8(acc)
                    }
                }
            }
            cur = out; cw = newW
        }
        if newH != h {
            let (b, k) = coeffs(h, newH)
            var out = [UInt8](repeating: 0, count: cw * newH * 3)
            for y in 0..<newH {
                let (ymin, n) = b[y]
                for x in 0..<cw {
                    for c in 0..<3 {
                        var acc: Int32 = 1 << 21
                        for i in 0..<n { acc += Int32(cur[((ymin + i) * cw + x) * 3 + c]) * k[y][i] }
                        out[(y * cw + x) * 3 + c] = clip8(acc)
                    }
                }
            }
            cur = out
        }
        return cur
    }

    public static func record(embedding: [Float], text: ClipText, threshold: Double, topK: Int) -> SemanticRecord {
        let norm = Float(embedding.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
        let emb = embedding.map { $0 / max(norm, 1e-12) }
        func logit(_ t: [Float]) -> Double {
            text.logitScale * Double(zip(emb, t).reduce(Float(0)) { $0 + $1.0 * $1.1 })
        }
        let aesthetic = softmax(text.aesthetic.prefix(2).map(logit))
        return SemanticRecord(
            aestheticScore: aesthetic.first.map(round4),
            model: text.model,
            scenes: rank(text.scenes.map(\.key), text.scenes.map { logit($0.embedding) }, threshold, topK),
            objects: rank(text.objects.map(\.key), text.objects.map { logit($0.embedding) }, threshold, topK),
            embedding: emb)
    }

    public static func analyze(_ images: [RGBImage], threshold: Double, topK: Int) throws -> [SemanticRecord] {
        if images.isEmpty { return [] }
        let text = try textOverride ?? ClipText.load(ModelStore.modelsDir.appendingPathComponent("clip_text.json"))
        let embeddings = try (embedder ?? defaultEmbedder)(images)
        return embeddings.map { record(embedding: $0, text: text, threshold: threshold, topK: topK) }
    }

    private static func defaultEmbedder(_ images: [RGBImage]) throws -> [[Float]] {
        try images.map { image in
            let out = try ModelStore.predict("clip_vision", inputs: ["pixel_values": preprocess(image)])
            guard let e = out["image_embeds"] else { throw AilbumError.decode("clip_vision: missing image_embeds") }
            return e
        }
    }

    private static func round4(_ v: Double) -> Double { (v * 10000).rounded(.toNearestOrEven) / 10000 }

    private static func softmax(_ v: [Double]) -> [Double] {
        guard let m = v.max() else { return [] }
        let e = v.map { exp($0 - m) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    private static func rank(_ labels: [String], _ logits: [Double], _ threshold: Double, _ topK: Int) -> [TagRecord] {
        let p = softmax(logits)
        let order = p.indices.sorted { p[$0] != p[$1] ? p[$0] > p[$1] : $0 < $1 }
        return order.filter { p[$0] >= threshold }.prefix(topK).map { TagRecord(label: labels[$0], confidence: round4(p[$0])) }
    }
}
