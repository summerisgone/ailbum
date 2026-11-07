import CryptoKit
import Foundation
import ImageIO

public enum Metadata {
    public static func collect(path: String, source: String) throws -> ImageMetadata {
        let resolved = realPath(path)
        var isDir: ObjCBool = false
        let sourceIsDir = FileManager.default.fileExists(atPath: source, isDirectory: &isDir) && isDir.boolValue
        let sourceRoot = realPath(sourceIsDir ? source : (source as NSString).deletingLastPathComponent)
        var st = stat()
        guard stat(resolved, &st) == 0 else {
            throw AilbumError.invalid("Не удалось прочитать файл: \(path)")
        }
        let fileName = (resolved as NSString).lastPathComponent
        let ext = (resolved as NSString).pathExtension
        let sha = try sha256(resolved)
        let modified = isoUTC(st.st_mtimespec)
        let created = isoUTC(st.st_birthtimespec)
        let relative = relativePath(resolved, sourceRoot) ?? fileName

        var meta = ImageMetadata(
            path: resolved, sourceRoot: sourceRoot, relativePath: relative, fileName: fileName,
            extension: ext.isEmpty ? "" : "." + ext.lowercased(),
            fileSizeBytes: Int(st.st_size), modifiedAt: modified, createdAt: created, sha256: sha,
            takenAt: filenameTakenAt(fileName))

        let url = URL(fileURLWithPath: resolved)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(src) == .statusComplete,
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        else {
            meta.extractionError = "UnidentifiedImageError: cannot identify image file '\(resolved)'"
            return meta
        }

        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exifDict = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gpsDict = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        var ifd0 = jsonObject(tiff)
        if ifd0["Orientation"] == nil, let o = props[kCGImagePropertyOrientation as String] {
            ifd0["Orientation"] = jsonValue(o)
        }
        let exifSection = jsonObject(exifDict)
        var sections: [String: JSONValue] = ["ifd0": .object(ifd0)]
        if !exifSection.isEmpty { sections["exif"] = .object(exifSection) }
        let gps = pillowGPS(gpsDict)
        if !gps.isEmpty { sections["gps"] = .object(gps) }
        let flattened = ifd0.merging(exifSection) { _, new in new }
        let (lat, lon, alt) = gpsCoordinates(gps)

        let uti = CGImageSourceGetType(src) as String?
        let format = uti.flatMap { formats[$0] }
        meta.mimeType = format.map { $0.1 }
        meta.imageFormat = format.map { $0.0 }
        meta.colorMode = colorMode(props)
        meta.width = w
        meta.height = h
        meta.frameCount = CGImageSourceGetCount(src)
        meta.orientation = asInt(flattened["Orientation"])
        meta.takenAt = takenAt(flattened) ?? filenameTakenAt(fileName)
        meta.cameraMake = asText(flattened["Make"])
        meta.cameraModel = asText(flattened["Model"])
        meta.lensModel = asText(flattened["LensModel"])
        meta.software = asText(flattened["Software"])
        meta.gpsLatitude = lat
        meta.gpsLongitude = lon
        meta.gpsAltitude = alt
        meta.exif = .object(sections)
        var container: [String: JSONValue] = [:]
        if let dx = (props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue,
           let dy = (props[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue {
            container["dpi"] = [.double(dx), .double(dy)]
        }
        meta.containerMetadata = .object(container)
        return meta
    }

    // MARK: helpers

    private static let formats: [String: (String, String)] = [
        "public.jpeg": ("JPEG", "image/jpeg"),
        "public.png": ("PNG", "image/png"),
        "com.compuserve.gif": ("GIF", "image/gif"),
        "public.tiff": ("TIFF", "image/tiff"),
        "com.microsoft.bmp": ("BMP", "image/bmp"),
        "org.webmproject.webp": ("WEBP", "image/webp"),
        "public.heic": ("HEIF", "image/heif"),
        "public.heif": ("HEIF", "image/heif"),
    ]

    private static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }

    private static func relativePath(_ path: String, _ root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    private static func sha256(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw AilbumError.invalid("Не удалось прочитать файл: \(path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Python `datetime.fromtimestamp(t, utc).isoformat()`.
    private static func isoUTC(_ ts: timespec) -> String {
        var micros = Int((Double(ts.tv_nsec) / 1000).rounded(.toNearestOrEven))
        var seconds = ts.tv_sec
        if micros == 1_000_000 { micros = 0; seconds += 1 }
        var t = time_t(seconds)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1,
                       Int(tmv.tm_mday), Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec))
        if micros != 0 { s += String(format: ".%06d", micros) }
        return s + "+00:00"
    }

    private static func colorMode(_ props: [String: Any]) -> String? {
        let model = props[kCGImagePropertyColorModel as String] as? String
        let alpha = (props[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? false
        switch model {
        case "RGB": return alpha ? "RGBA" : "RGB"
        case "Gray": return alpha ? "LA" : "L"
        case "CMYK": return "CMYK"
        case "Lab": return "LAB"
        default: return model
        }
    }

    static func jsonValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        case let a as [Any]: return .array(a.map(jsonValue))
        case let d as [String: Any]: return .object(jsonObject(d))
        case let d as Data:
            return .object(["encoding": "base64", "value": .string(d.base64EncodedString())])
        default: return .string("\(value)")
        }
    }

    private static func jsonObject(_ dict: [String: Any]) -> [String: JSONValue] {
        dict.mapValues(jsonValue)
    }

    /// ImageIO exposes GPS as positive decimal degrees plus refs; rebuild Pillow-style D/M/S lists.
    private static func pillowGPS(_ gps: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in gps {
            switch key {
            case "Latitude", "Longitude":
                if let d = (value as? NSNumber)?.doubleValue {
                    let degrees = d.rounded(.down)
                    let minutesFull = (d - degrees) * 60
                    let minutes = minutesFull.rounded(.down)
                    out["GPS" + key] = [.double(degrees), .double(minutes), .double((minutesFull - minutes) * 60)]
                }
            default:
                out["GPS" + key] = jsonValue(value)
            }
        }
        return out
    }

    static func gpsCoordinates(_ gps: [String: JSONValue]) -> (Double?, Double?, Double?) {
        var latitude = dms(gps["GPSLatitude"])
        var longitude = dms(gps["GPSLongitude"])
        if latitude != nil, (gps["GPSLatitudeRef"].map(pyStr) ?? "N").uppercased() == "S" { latitude = -latitude! }
        if longitude != nil, (gps["GPSLongitudeRef"].map(pyStr) ?? "E").uppercased() == "W" { longitude = -longitude! }
        var altitude = number(gps["GPSAltitude"])
        if altitude != nil, asInt(gps["GPSAltitudeRef"]) == 1 { altitude = -altitude! }
        if latitude == 0.0 && longitude == 0.0 { latitude = nil; longitude = nil }
        return (latitude, longitude, altitude)
    }

    private static func dms(_ value: JSONValue?) -> Double? {
        guard case .array(let items)? = value, items.count == 3 else { return nil }
        let parts = items.map { number($0) }
        guard let d = parts[0], let m = parts[1], let s = parts[2] else { return nil }
        return d + m / 60 + s / 3600
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .object(let o)?: return o["decimal"].flatMap { number($0) }
        default: return nil
        }
    }

    private static func asInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i)?: return i
        case .double(let d)?: return d.isFinite && abs(d) < 9e18 ? Int(d) : nil
        default: return nil
        }
    }

    private static func pyStr(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        default: return ""
        }
    }

    private static func asText(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        return pyStr(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func takenAt(_ tags: [String: JSONValue]) -> String? {
        let candidates = [("DateTimeOriginal", "OffsetTimeOriginal"),
                          ("DateTimeDigitized", "OffsetTimeDigitized"),
                          ("DateTime", "OffsetTime")]
        for (dateKey, offsetKey) in candidates {
            guard case .string(let value)? = tags[dateKey] else { continue }
            guard let base = parseExifDate(value) else { continue }
            if case .string(let offset)? = tags[offsetKey] {
                guard let off = parseOffset(offset) else { continue }
                return base + off
            }
            return base
        }
        return nil
    }

    private static func parseExifDate(_ value: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$"#)
        let ns = value as NSString
        guard let m = re.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let n = (1...6).map { Int(ns.substring(with: m.range(at: $0)))! }
        guard validDateTime(n) else { return nil }
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", n[0], n[1], n[2], n[3], n[4], n[5])
    }

    private static func validDateTime(_ n: [Int]) -> Bool {
        guard n[0] >= 1, (1...12).contains(n[1]), n[3] < 24, n[4] < 60, n[5] < 60 else { return false }
        var c = DateComponents(); c.year = n[0]; c.month = n[1]; c.day = 1
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let first = cal.date(from: c), let days = cal.range(of: .day, in: .month, for: first) else { return false }
        return days.contains(n[2])
    }

    /// `%z`: Z, +HH[:]MM[[:]SS]; isoformat prints +HH:MM[:SS].
    private static func parseOffset(_ value: String) -> String? {
        if value == "Z" { return "+00:00" }
        let re = try! NSRegularExpression(pattern: #"^([+-])(\d{2}):?(\d{2})(?::?(\d{2}))?$"#)
        let ns = value as NSString
        guard let m = re.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let sign = ns.substring(with: m.range(at: 1))
        let hh = Int(ns.substring(with: m.range(at: 2)))!
        let mm = Int(ns.substring(with: m.range(at: 3)))!
        let ss = m.range(at: 4).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 4)))!
        guard mm < 60, ss < 60, hh < 24 else { return nil }
        if hh == 0 && mm == 0 && ss == 0 { return "+00:00" }
        var s = "\(sign)" + String(format: "%02d:%02d", hh, mm)
        if ss != 0 { s += String(format: ":%02d", ss) }
        return s
    }

    static func filenameTakenAt(_ name: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"(?<!\d)(20\d{6})[_-]?(\d{6})(?!\d)"#)
        let ns = name as NSString
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let d = ns.substring(with: m.range(at: 1)), t = ns.substring(with: m.range(at: 2))
        let digits = Array(d + t).compactMap { $0.wholeNumberValue }
        guard digits.count == 14 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int { digits[a..<b].reduce(0) { $0 * 10 + $1 } }
        let n = [num(0, 4), num(4, 6), num(6, 8), num(8, 10), num(10, 12), num(12, 14)]
        guard validDateTime(n) else { return nil }
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", n[0], n[1], n[2], n[3], n[4], n[5])
    }
}
