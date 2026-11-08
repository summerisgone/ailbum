import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AssistantChoice: Equatable, Sendable {
    public var index: Int
    public var reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

/// Asks a local LM Studio VLM to pick the best of several spread layouts.
public final class LayoutAssistant {
    static let labels = "ABCDEF"
    static let maxReason = 200
    static let maxWish = 300

    public let baseURL: String
    public private(set) var model: String
    public let timeout: Double
    private let transport: StoryNamer.Transport

    public init(baseURL: String, model: String, timeout: Double = 90.0, transport: StoryNamer.Transport? = nil) {
        var url = baseURL
        while url.hasSuffix("/") { url.removeLast() }
        self.baseURL = url
        self.model = model
        self.timeout = timeout
        self.transport = transport ?? StoryNamer.urlSessionTransport
    }

    public func connect() -> Bool {
        do {
            let response = try requestJSON("\(baseURL)/models", nil, timeout: min(timeout, 10.0))
            if model.isEmpty {
                guard let models = response["data"] as? [[String: Any]], let first = models.first,
                      let id = first["id"] else { return false }
                model = "\(id)"
            }
        } catch {
            return false
        }
        return true
    }

    public func choose(
        _ variants: [SpreadDraft], paths: [Int: String], orientation: String, storyTitle: String,
        wish: String = ""
    ) -> AssistantChoice? {
        let count = min(variants.count, LayoutAssistant.labels.count)
        if count < 2 { return nil }
        let letters = LayoutAssistant.labels.prefix(count).map { String($0) }.joined(separator: ", ")
        let trimmedWish = LayoutAssistant.pyStrip(wish)
        let wishText = trimmedWish.isEmpty
            ? "" : "Пожелание автора альбома: «\(LayoutAssistant.clip(trimmedWish, LayoutAssistant.maxWish))». "
        let prompt =
            "На листе показаны варианты раскладки одного разворота фотоальбома, подписанные "
            + "\(letters). Сюжет: «\(storyTitle)». Выбери вариант, который лучше читается как "
            + "история и выглядит сбалансированнее: крупный кадр у главного момента, ровный "
            + "ритм, без перегруза. Все варианты допустимы, лица не обрезаны. "
            + wishText
            + "Верни только JSON вида {\"choice\":\"A\",\"reason\":\"коротко почему\"}."
        let raw: Any
        do {
            let sheet = try LayoutAssistant.renderVariants(
                Array(variants.prefix(count)), paths: paths, orientation: orientation)
            let url = "data:image/jpeg;base64," + sheet.base64EncodedString()
            let response = try requestJSON(
                "\(baseURL)/chat/completions",
                [
                    "model": model,
                    "messages": [
                        [
                            "role": "user",
                            "content": [
                                ["type": "text", "text": prompt],
                                ["type": "image_url", "image_url": ["url": url]],
                            ] as [[String: Any]],
                        ] as [String: Any]
                    ],
                    "temperature": 0.1,
                    "max_tokens": 200,
                    "stream": false,
                ],
                timeout: timeout)
            guard let choices = response["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] else { return nil }
            raw = content
        } catch {
            return nil
        }
        return LayoutAssistant.parseChoice(raw, count)
    }

    private func requestJSON(_ url: String, _ payload: [String: Any]?, timeout: Double) throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw AilbumError.invalid("Не удалось подключиться к LM Studio: bad URL \(url)")
        }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = payload == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        let data: Data
        do {
            data = try transport(request)
        } catch let e as URLError {
            throw AilbumError.invalid("Не удалось подключиться к LM Studio: \(e.localizedDescription)")
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AilbumError.invalid("LM Studio вернул ответ не в формате JSON-объекта")
        }
        return result
    }

    /// Python `str.strip()`: Unicode whitespace plus the \x1c-\x1f separators.
    static func pyStrip(_ text: String) -> String {
        func space(_ u: Unicode.Scalar) -> Bool {
            (0x1c...0x1f).contains(u.value) || CharacterSet.whitespacesAndNewlines.contains(u)
        }
        var scalars = text.unicodeScalars[...]
        while let f = scalars.first, space(f) { scalars.removeFirst() }
        while let l = scalars.last, space(l) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    /// Mirrors Python `_parse_choice`: first decodable JSON object with a valid letter wins.
    static func parseChoice(_ raw: Any, _ count: Int) -> AssistantChoice? {
        guard let text = raw as? String else { return nil }
        let chars = Array(text.unicodeScalars)
        for start in chars.indices where chars[start] == "{" {
            guard let end = objectEnd(chars, start) else { continue }
            let slice = String(String.UnicodeScalarView(chars[start...end]))
            guard let data = slice.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let letter = obj["choice"] as? String else { continue }
            let trimmed = pyStrip(letter)
            guard trimmed.unicodeScalars.count == 1 else { continue }
            let upper = trimmed.uppercased()
            guard let index = labels.map({ String($0) }).firstIndex(of: upper), index < count else { continue }
            var reason = ""
            if let value = obj["reason"] as? String {
                var cleaned = ""
                var inControl = false
                for scalar in value.unicodeScalars {
                    if scalar.value <= 0x1f || scalar.value == 0x7f {
                        if !inControl { cleaned += " " }
                        inControl = true
                    } else {
                        cleaned.unicodeScalars.append(scalar)
                        inControl = false
                    }
                }
                reason = clip(pyStrip(cleaned), maxReason)
            }
            return AssistantChoice(index: index, reason: reason)
        }
        return nil
    }

    private static func objectEnd(_ chars: [Unicode.Scalar], _ start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: rendering

    public static func renderVariants(
        _ variants: [SpreadDraft], paths: [Int: String], orientation: String, maxSide: Int = 896
    ) throws -> Data {
        let fmt = try Templates.formatFor(orientation)
        var byId: [String: Template] = [:]
        for template in try Templates.templatesFor(orientation) where byId[template.id] == nil {
            byId[template.id] = template
        }
        let width = 1200
        let height = max(1, Int((Double(width) * fmt.spreadHmm / fmt.spreadWmm).rounded(.toNearestOrEven)))
        let scale = Double(width) / fmt.spreadWmm
        let labelH = 56
        let pad = 12
        let sheetW = width + 2 * pad
        let sheetH = variants.count * (height + labelH + pad) + pad
        guard let ctx = CGContext(
            data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AilbumError.decode("не удалось создать лист вариантов") }
        ctx.interpolationQuality = .high
        // Top-left origin, as PIL.
        ctx.translateBy(x: 0, y: CGFloat(sheetH))
        ctx.scaleBy(x: 1, y: -1)
        fill(ctx, 255, CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        for (number, variant) in variants.enumerated() {
            var top = pad + number * (height + labelH + pad)
            drawLabel(ctx, String(labels[labels.index(labels.startIndex, offsetBy: number % labels.count)]),
                      font: font, x: pad, top: top)
            top += labelH
            fill(ctx, 235, CGRect(x: pad, y: top, width: width + 1, height: height + 1))
            if let template = byId[variant.templateId] {
                var cells: [Int: Cell] = [:]
                for cell in template.cells { cells[cell.index] = cell }
                for placement in variant.placements {
                    if let cell = cells[placement.cellIndex] {
                        pasteCell(ctx, cell.rect, placement, paths, pad, top, scale)
                    }
                }
            }
            fill(ctx, 120, CGRect(x: pad + width / 2 - 1, y: top, width: 2, height: height + 1))
        }
        guard let full = ctx.makeImage() else { throw AilbumError.decode("не удалось создать лист вариантов") }
        let limit = max(1, maxSide)
        var outImage = full
        if sheetW > limit || sheetH > limit {
            let ratio = min(Double(limit) / Double(sheetW), Double(limit) / Double(sheetH))
            let nw = min(limit, max(1, Int((Double(sheetW) * ratio).rounded())))
            let nh = min(limit, max(1, Int((Double(sheetH) * ratio).rounded())))
            guard let small = CGContext(
                data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw AilbumError.decode("не удалось уменьшить лист вариантов") }
            small.interpolationQuality = .high
            small.draw(full, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            guard let scaled = small.makeImage() else { throw AilbumError.decode("не удалось уменьшить лист вариантов") }
            outImage = scaled
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AilbumError.decode("не удалось закодировать JPEG")
        }
        CGImageDestinationAddImage(dest, outImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AilbumError.decode("не удалось закодировать JPEG") }
        return out as Data
    }

    private static func fill(_ ctx: CGContext, _ gray: Int, _ rect: CGRect) {
        let v = CGFloat(gray) / 255
        ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
        ctx.fill(rect)
    }

    private static func drawLabel(_ ctx: CGContext, _ text: String, font: CTFont, x: Int, top: Int) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(top) + CTFontGetAscent(font))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func pasteCell(
        _ ctx: CGContext, _ rect: Rect, _ placement: PlacementDraft, _ paths: [Int: String],
        _ left: Int, _ top: Int, _ scale: Double
    ) {
        let x0 = left + Int((rect.x * scale).rounded(.toNearestOrEven))
        let y0 = top + Int((rect.y * scale).rounded(.toNearestOrEven))
        let w = max(1, Int((rect.w * scale).rounded(.toNearestOrEven)))
        let h = max(1, Int((rect.h * scale).rounded(.toNearestOrEven)))
        let frame = CGRect(x: x0, y: y0, width: w, height: h)
        ctx.saveGState()
        ctx.clip(to: frame)
        if let tile = photoTile(paths[placement.imageId], placement.crop) {
            // Flip back so the image is upright in the top-left-origin context.
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            fill(ctx, 170, frame)
            ctx.setStrokeColor(CGColor(red: 110 / 255, green: 110 / 255, blue: 110 / 255, alpha: 1))
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: frame.minX, y: frame.minY))
            ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: x0, y: y0, width: w, height: min(3, h)))
        ctx.fill(CGRect(x: x0, y: max(y0, y0 + h - 3), width: w, height: min(3, h)))
        ctx.fill(CGRect(x: x0, y: y0, width: min(3, w), height: h))
        ctx.fill(CGRect(x: max(x0, x0 + w - 3), y: y0, width: min(3, w), height: h))
    }

    /// Cropped photo, or nil when the file is missing or unreadable.
    private static func photoTile(_ path: String?, _ crop: Rect) -> CGImage? {
        guard let path, let image = try? ImageLoader.load(path: path) else { return nil }
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            for c in 0..<3 { rgba[i * 4 + c] = image.pixels[i * 3 + c] }
        }
        let cg: CGImage? = rgba.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let cg else { return nil }
        let w = Double(image.width)
        let h = Double(image.height)
        let x0 = min(max(crop.x, 0), 1)
        let y0 = min(max(crop.y, 0), 1)
        let x1 = min(max(crop.x + crop.w, x0), 1)
        let y1 = min(max(crop.y + crop.h, y0), 1)
        let left = Int(x0 * w)
        let upper = Int(y0 * h)
        let right = min(image.width, max(left + 1, Int((x1 * w).rounded(.toNearestOrEven))))
        let lower = min(image.height, max(upper + 1, Int((y1 * h).rounded(.toNearestOrEven))))
        return cg.cropping(to: CGRect(x: left, y: upper, width: max(1, right - left), height: max(1, lower - upper)))
    }
}
