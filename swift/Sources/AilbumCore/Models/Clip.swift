import CoreGraphics
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

    /// Resize shortest side to 224 (bicubic-class), centre crop, normalise; shape 1x3x224x224.
    public static func preprocess(_ image: RGBImage) -> MLMultiArray {
        let size = 224
        let short = min(image.width, image.height)
        let newW = image.width <= image.height ? size : max(size, Int(Double(size) * Double(image.width) / Double(short)))
        let newH = image.width <= image.height ? max(size, Int(Double(size) * Double(image.height) / Double(short))) : size
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            rgba[i * 4] = image.pixels[i * 3]
            rgba[i * 4 + 1] = image.pixels[i * 3 + 1]
            rgba[i * 4 + 2] = image.pixels[i * 3 + 2]
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        var resized = [UInt8](repeating: 0, count: newW * newH * 4)
        rgba.withUnsafeMutableBytes { src in
            let sctx = CGContext(
                data: src.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: info)
            guard let cg = sctx?.makeImage() else { return }
            resized.withUnsafeMutableBytes { dst in
                let ctx = CGContext(
                    data: dst.baseAddress, width: newW, height: newH, bitsPerComponent: 8,
                    bytesPerRow: newW * 4, space: space, bitmapInfo: info)
                ctx?.interpolationQuality = .high
                ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            }
        }
        let out = try! MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let ptr = out.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        let ox = (newW - size) / 2, oy = (newH - size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let s = ((y + oy) * newW + x + ox) * 4
                for c in 0..<3 {
                    ptr[c * size * size + y * size + x] = (Float(resized[s + c]) / 255 - mean[c]) / std[c]
                }
            }
        }
        return out
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
