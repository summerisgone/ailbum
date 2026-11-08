import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Generates concise Russian story titles with a local LM Studio VLM.
public final class StoryNamer {
    public typealias Transport = (URLRequest) throws -> Data

    public let requestedBackend: String
    public let baseURL: String
    public private(set) var model: String?
    public let maxImages: Int
    public let timeout: Double
    public private(set) var backend = "rules"
    public private(set) var error: String?
    private let transport: Transport

    public init(
        backend: String = "auto",
        baseURL: String = "http://127.0.0.1:1234/v1",
        model: String? = "qwen/qwen3-vl-2b",
        maxImages: Int = 4,
        timeout: Double = 90.0,
        transport: Transport? = nil
    ) throws {
        guard ["auto", "rules", "off", "lmstudio"].contains(backend) else {
            throw AilbumError.invalid("Unsupported story naming backend: \(backend)")
        }
        guard (1...8).contains(maxImages) else {
            throw AilbumError.invalid("Story VLM image count must be between 1 and 8")
        }
        guard timeout > 0 else { throw AilbumError.invalid("Story VLM timeout must be positive") }
        self.requestedBackend = backend == "off" ? "rules" : backend
        var url = baseURL
        while url.hasSuffix("/") { url.removeLast() }
        self.baseURL = url
        self.model = model
        self.maxImages = maxImages
        self.timeout = timeout
        self.transport = transport ?? StoryNamer.urlSessionTransport
    }

    public func refine(_ stories: [StoryRecord], photoPaths: [String: String]) throws -> [StoryRecord] {
        let pending = stories.filter { StoryNamer.needsVLMTitle($0.title) }
        if requestedBackend == "rules" || pending.isEmpty { return stories }
        do {
            try connect()
        } catch let e {
            error = "\(type(of: e)): \(StoryNamer.describe(e))"
            if requestedBackend == "lmstudio" {
                throw AilbumError.invalid(
                    "LM Studio недоступен. Запустите `lms server start` и загрузите VL-модель.")
            }
            return stories
        }
        var result = stories
        for index in result.indices where StoryNamer.needsVLMTitle(result[index].title) {
            let paths = result[index].photoIds.compactMap { photoPaths[$0] }
            do {
                if let title = try nameStory(result[index], paths) {
                    result[index].title = title
                    result[index].namingModel = model
                }
            } catch let e {
                error = "\(type(of: e)): \(StoryNamer.describe(e))"
            }
        }
        return result
    }

    private func connect() throws {
        let response = try requestJSON("\(baseURL)/models", nil, timeout: min(timeout, 10.0))
        if model == nil || model!.isEmpty {
            guard let models = response["data"] as? [[String: Any]], let first = models.first,
                  let id = first["id"] else {
                throw AilbumError.invalid("В LM Studio нет доступной модели")
            }
            model = "\(id)"
        }
        backend = "lmstudio"
    }

    private func nameStory(_ story: StoryRecord, _ paths: [String]) throws -> String? {
        let selected = StoryNamer.evenlySpaced(paths, maxImages)
        if selected.isEmpty { return nil }
        let tags = (Array(story.sceneLabels.prefix(6)) + Array(story.objectLabels.prefix(6)))
            .joined(separator: ", ")
        let prompt =
            "Перед тобой несколько кадров одного непрерывного эпизода фотоальбома. "
            + "Определи реальный сюжет по всем кадрам вместе. Дай короткое информативное "
            + "название на русском языке из 2–7 слов: отрази место, время суток и занятие "
            + "людей или повод, если это видно. Не используй общие названия «Событие», "
            + "«Фотоистория», «Сюжет», «Встреча» без конкретного уточнения. Не считай стол "
            + "или еду главным сюжетом, если большинство кадров о другом. Не выдумывай "
            + "детали. Текущее название по CV: «\(story.title)». Сохрани его, если оно "
            + "точнее описывает место, время и действие. Вспомогательные CV-теги "
            + "(могут ошибаться): \(tags.isEmpty ? "нет" : tags). "
            + "Верни только JSON вида {\"title\":\"...\"}."
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for path in selected {
            content.append(["type": "image_url", "image_url": ["url": try StoryNamer.imageDataURL(path)]])
        }
        let response = try requestJSON(
            "\(baseURL)/chat/completions",
            [
                "model": model ?? "",
                "messages": [["role": "user", "content": content]],
                "temperature": 0.1,
                "max_tokens": 120,
                "stream": false,
            ],
            timeout: timeout)
        guard let choices = response["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] else {
            throw AilbumError.invalid("LM Studio вернул неожиданный ответ")
        }
        return StoryNamer.parseTitle(raw)
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

    static func describe(_ e: Error) -> String {
        if case AilbumError.invalid(let m) = e { return m }
        return "\(e)"
    }

    static let urlSessionTransport: Transport = { request in
        nonisolated(unsafe) var out: Result<Data, Error> = .failure(URLError(.unknown))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, err in
            if let err {
                out = .failure(err)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let detail = String(decoding: data ?? Data(), as: UTF8.self)
                out = .failure(AilbumError.invalid(
                    "LM Studio вернул HTTP \(http.statusCode): \(String(detail.prefix(300)))"))
            } else {
                out = .success(data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }

    static func imageDataURL(_ path: String, maxSide: Int = 896) throws -> String {
        var image = try ImageLoader.load(path: path)
        let longest = max(image.width, image.height)
        if longest > maxSide {
            let scale = Double(maxSide) / Double(longest)
            image = Resize.area(
                image, width: max(1, Int((Double(image.width) * scale).rounded())),
                height: max(1, Int((Double(image.height) * scale).rounded())))
        }
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
        let out = NSMutableData()
        guard let cg, let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AilbumError.decode("не удалось закодировать JPEG: \(path)")
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw AilbumError.decode("не удалось закодировать JPEG: \(path)")
        }
        return "data:image/jpeg;base64,\((out as Data).base64EncodedString())"
    }

    static func evenlySpaced(_ paths: [String], _ limit: Int) -> [String] {
        if paths.count <= limit { return paths }
        if limit == 1 { return [paths[paths.count / 2]] }
        var seen = Set<Int>()
        var picked: [String] = []
        for i in 0..<limit {
            let idx = Int((Double(i * (paths.count - 1)) / Double(limit - 1)).rounded(.toNearestOrEven))
            if seen.insert(idx).inserted { picked.append(paths[idx]) }
        }
        return picked
    }

    static func parseTitle(_ value: Any) -> String? {
        var text: String
        if let list = value as? [Any] {
            text = list.compactMap { ($0 as? [String: Any]).map { "\($0["text"] ?? "")" } }.joined()
        } else if let s = value as? String {
            text = s
        } else {
            return nil
        }
        guard let range = text.range(of: "\\{[^{}]*\\}", options: .regularExpression),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[range].utf8)) as? [String: Any]
        else { return nil }
        let strip = CharacterSet(charactersIn: "\"«»")
        var title = "\(obj["title"] ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: strip)
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let lowered = title.lowercased()
        guard (3...80).contains(title.unicodeScalars.count) else { return nil }
        if ["событие", "фотоистория", "сюжет", "встреча"].contains(where: lowered.hasPrefix) { return nil }
        if ["дай ", "как ", "совет", "лайфхак"].contains(where: lowered.hasPrefix) || title.contains("?") {
            return nil
        }
        return title
    }

    static func needsVLMTitle(_ title: String) -> Bool {
        title.hasPrefix("Фотографии ") || title.hasPrefix("Совместный отдых")
    }
}
