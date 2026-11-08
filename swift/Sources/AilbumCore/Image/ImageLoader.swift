import Foundation
import ImageIO
import CoreGraphics

public enum ImageLoader {
    static let suffixes: Set<String> = ["jpg", "jpeg", "png", "webp", "tif", "tiff"]

    public static func load(path: String) throws -> RGBImage {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { throw AilbumError.decode("не удалось открыть изображение: \(path)") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw AilbumError.decode("не удалось декодировать изображение: \(path)")
        }
        let w = cg.width, h = cg.height
        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgbx.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw AilbumError.decode("не удалось создать контекст: \(path)") }
        var pixels = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            pixels[i * 3] = rgbx[i * 4]
            pixels[i * 3 + 1] = rgbx[i * 4 + 1]
            pixels[i * 3 + 2] = rgbx[i * 4 + 2]
        }
        return RGBImage(width: w, height: h, pixels: pixels)
    }

    public static func takenAt(path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }

    public static func discover(root: String, recursive: Bool) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        func ok(_ p: String) -> Bool { suffixes.contains((p as NSString).pathExtension.lowercased()) }
        if recursive {
            guard let en = fm.enumerator(atPath: root) else { return [] }
            for case let rel as String in en {
                let full = (root as NSString).appendingPathComponent(rel)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue, ok(full) { found.append(full) }
            }
        } else {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let full = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue, ok(full) { found.append(full) }
            }
        }
        return found.sorted()
    }
}
