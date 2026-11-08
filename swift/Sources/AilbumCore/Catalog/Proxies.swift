import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Proxies {
    static let photoSide = 1600
    static let photoQuality = 0.82
    static let faceSize = 240
    static let faceQuality = 0.86

    private static func parent(_ database: String) -> String {
        let p = (database as NSString).deletingLastPathComponent
        return p.isEmpty ? "." : p
    }

    public static func photoProxy(database: String, sha256: String) -> String {
        parent(database) + "/proxies/photos/\(sha256).jpg"
    }

    static func faceProxy(database: String, faceId: Int) -> String {
        parent(database) + "/proxies/faces/\(faceId).jpg"
    }

    private static func int(_ value: SQLValue?) -> Int {
        switch value {
        case .integer(let v)?: return Int(v)
        case .real(let v)?: return Int(v)
        case .text(let s)?: return Int(s) ?? 0
        default: return 0
        }
    }

    private static func text(_ value: SQLValue?) -> String {
        switch value {
        case .text(let s)?: return s
        case .integer(let v)?: return String(v)
        case .real(let v)?: return String(v)
        default: return ""
        }
    }

    private static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func validJPEG(_ path: String) -> Bool {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src), (type as String) == UTType.jpeg.identifier,
              CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
        else { return false }
        return true
    }

    private static func cgImage(_ image: RGBImage) -> CGImage? {
        var rgbx = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            rgbx[i * 4] = image.pixels[i * 3]
            rgbx[i * 4 + 1] = image.pixels[i * 3 + 1]
            rgbx[i * 4 + 2] = image.pixels[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgbx) as CFData) else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Crops `rect` (pixel coordinates) and scales it to width x height with high-quality interpolation.
    private static func scaled(_ image: RGBImage, crop rect: CGRect, width: Int, height: Int) throws -> CGImage {
        guard let full = cgImage(image), let cropped = full.cropping(to: rect),
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AilbumError.decode("не удалось подготовить изображение") }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw AilbumError.decode("не удалось подготовить изображение") }
        return out
    }

    private static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AilbumError.decode("не удалось создать JPEG")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AilbumError.decode("не удалось создать JPEG") }
        return data as Data
    }

    private static func photoBytes(_ image: RGBImage) throws -> Data {
        let longest = max(image.width, image.height)
        var w = image.width, h = image.height
        if longest > photoSide {
            let scale = Double(photoSide) / Double(longest)
            w = max(1, Int((Double(image.width) * scale).rounded(.toNearestOrEven)))
            h = max(1, Int((Double(image.height) * scale).rounded(.toNearestOrEven)))
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return try jpegData(try scaled(image, crop: rect, width: w, height: h), quality: photoQuality)
    }

    private static func faceTile(_ image: RGBImage, face: [String: SQLValue], scale: Double = 1.0) throws -> Data {
        func real(_ key: String) -> Double {
            switch face[key] {
            case .integer(let v)?: return Double(v)
            case .real(let v)?: return v
            default: return 0
            }
        }
        let x = real("bbox_x") * scale, y = real("bbox_y") * scale
        let width = real("bbox_width") * scale, height = real("bbox_height") * scale
        func round(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        let margin = round(max(width, height) * 0.2)
        let left = max(0, round(x) - margin), top = max(0, round(y) - margin)
        let right = min(image.width, round(x + width) + margin), bottom = min(image.height, round(y + height) + margin)
        let cw = right - left, ch = bottom - top
        guard cw > 0, ch > 0 else { throw AilbumError.invalid("empty face crop") }
        // ImageOps.fit: centered crop to the square target aspect.
        let side = min(cw, ch)
        let rect = CGRect(x: left + (cw - side) / 2, y: top + (ch - side) / 2, width: side, height: side)
        return try jpegData(try scaled(image, crop: rect, width: faceSize, height: faceSize), quality: faceQuality)
    }

    private static func writeAtomic(_ path: String, _ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temp))
            guard validJPEG(temp) else {
                throw AilbumError.invalid("Proxy verification failed: \((path as NSString).lastPathComponent)")
            }
            guard rename(temp, path) == 0 else { throw AilbumError.invalid("Proxy write failed: \(path)") }
        } catch {
            try? fm.removeItem(atPath: temp)
            throw error
        }
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case AilbumError.invalid(let m), AilbumError.decode(let m), AilbumError.sqlite(let m): return m
        default: return String(describing: error)
        }
    }

    public static func build(database: String, imageIds: [Int]) throws -> JSONValue {
        var built: [JSONValue] = []
        var failed: [JSONValue] = []
        let db = imageIds.isEmpty ? nil : try Database.open(path: database)
        for imageId in imageIds {
            do {
                guard let db else { break }
                let rows = try db.query(
                    "SELECT id, path, sha256, availability FROM images WHERE id = ?", [.integer(imageId)])
                guard let row = rows.first else { throw AilbumError.invalid("image not found") }
                let target = photoProxy(database: database, sha256: text(row["sha256"]))
                let source = text(row["path"])
                var original: RGBImage?
                if text(row["availability"]) == "present", isFile(source) {
                    original = try ImageLoader.load(path: source)
                }
                if !(isFile(target) && validJPEG(target)) {
                    guard let original else { throw AilbumError.invalid("original unavailable") }
                    try writeAtomic(target, try photoBytes(original))
                }
                if let original {
                    let faces = try db.query(
                        "SELECT id, bbox_x, bbox_y, bbox_width, bbox_height FROM faces WHERE image_id = ?",
                        [.integer(imageId)])
                    for face in faces {
                        try writeAtomic(faceProxy(database: database, faceId: int(face["id"])), try faceTile(original, face: face))
                    }
                }
                built.append(.int(imageId))
            } catch {
                failed.append(["image_id": .int(imageId), "error": .string(message(error))])
            }
        }
        return ["built": .array(built), "failed": .array(failed)]
    }

    public static func imageSource(database: String, image: [String: SQLValue]) -> String? {
        if text(image["availability"]) == "present" {
            let path = text(image["path"])
            if isFile(path) { return path }
        }
        let sha = text(image["sha256"])
        guard !sha.isEmpty else { return nil }
        let proxy = photoProxy(database: database, sha256: sha)
        return isFile(proxy) ? proxy : nil
    }

    public static func faceThumbnail(database: String, faceId: Int) throws -> Data {
        let db = try Database.open(path: database)
        let rows = try db.query(
            """
            SELECT f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height, i.path, i.sha256,
                   i.availability, i.width, i.height, i.orientation
            FROM faces AS f JOIN images AS i ON i.id = f.image_id
            WHERE f.id = ?
            """, [.integer(faceId)])
        guard let face = rows.first else { throw AilbumError.invalid("Face id does not exist: \(faceId)") }
        let cached = faceProxy(database: database, faceId: faceId)
        if isFile(cached), validJPEG(cached) { return try Data(contentsOf: URL(fileURLWithPath: cached)) }
        let path = text(face["path"])
        if text(face["availability"]) == "present", isFile(path) {
            return try faceTile(try ImageLoader.load(path: path), face: face)
        }
        let proxy = photoProxy(database: database, sha256: text(face["sha256"]))
        guard isFile(proxy) else { throw AilbumError.invalid("No image source for face \(faceId)") }
        var width = int(face["width"])
        let orientation = int(face["orientation"])
        if [5, 6, 7, 8].contains(orientation == 0 ? 1 : orientation) { width = int(face["height"]) }
        let image = try ImageLoader.load(path: proxy)
        let scale = width != 0 ? Double(image.width) / Double(width) : 1.0
        return try faceTile(image, face: face, scale: scale)
    }
}
