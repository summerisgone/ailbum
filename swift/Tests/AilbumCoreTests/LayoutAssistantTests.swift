import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private struct LaFailure: Error {}

private func laDraft(_ ids: Int...) -> SpreadDraft {
    SpreadDraft(
        templateId: "pages", storyIds: [],
        placements: ids.enumerated().map { i, id in
            PlacementDraft(
                cellIndex: i, imageId: id, crop: Rect(x: 0, y: 0, w: 1, h: 1), fit: 1,
                warnings: [], replacedImageId: nil)
        },
        score: 0)
}

private func laTempDir() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-la-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func laMakeJpeg(_ path: String) -> String {
    let ctx = CGContext(
        data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 200 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    try? (out as Data).write(to: URL(fileURLWithPath: path))
    return path
}

private func laInfo(_ data: Data) -> (type: String, width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(src) as String?,
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return (type, img.width, img.height)
}

private func laThree() throws -> ([SpreadDraft], [Int: String]) {
    let dir = try laTempDir()
    let paths = [1: laMakeJpeg(dir + "/a.jpg"), 2: laMakeJpeg(dir + "/b.jpg")]
    return ([laDraft(1, 2), laDraft(2, 1), laDraft(1, 2)], paths)
}

private func laReply(_ content: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
}

private final class LaCalls: @unchecked Sendable {
    var requests: [URLRequest] = []
}

private func laAssistant(_ content: Any, calls: LaCalls? = nil, model: String = "m") -> LayoutAssistant {
    LayoutAssistant(
        baseURL: "http://x/v1", model: model,
        transport: { request in
            calls?.requests.append(request)
            return try laReply(content)
        })
}

private func laTexts(_ request: URLRequest) throws -> (url: String, text: String, image: String) {
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages[0]["content"] as? [[String: Any]])
    let image = try #require(parts[1]["image_url"] as? [String: Any])
    return (request.url?.absoluteString ?? "", parts[0]["text"] as? String ?? "", image["url"] as? String ?? "")
}

@Test func laRenderReturnsJpegWithinMaxSide() throws {
    let (variants, paths) = try laThree()
    let data = try LayoutAssistant.renderVariants(variants, paths: paths, orientation: "vertical", maxSide: 500)
    let info = try #require(laInfo(data))
    #expect(info.type == UTType.jpeg.identifier)
    #expect(max(info.width, info.height) <= 500)
}

@Test func laRenderSizeMatchesTileGrid() throws {
    let (variants, paths) = try laThree()
    let data = try LayoutAssistant.renderVariants(variants, paths: paths, orientation: "vertical", maxSide: 100_000)
    let fmt = try Templates.formatFor("vertical")
    let height = Int((1200 * fmt.spreadHmm / fmt.spreadWmm).rounded(.toNearestOrEven))
    let info = try #require(laInfo(data))
    #expect(info.width == 1224)
    #expect(info.height == 3 * (height + 56 + 12) + 12)
}

@Test func laMissingPhotoRendersPlaceholder() throws {
    let dir = try laTempDir()
    let data = try LayoutAssistant.renderVariants(
        [laDraft(1, 2)], paths: [1: dir + "/gone.jpg"], orientation: "vertical", maxSide: 400)
    #expect(laInfo(data)?.type == UTType.jpeg.identifier)
}

@Test func laCorruptPhotoRendersPlaceholder() throws {
    let dir = try laTempDir()
    try Data("not an image".utf8).write(to: URL(fileURLWithPath: dir + "/bad.jpg"))
    let data = try LayoutAssistant.renderVariants(
        [laDraft(1, 2)], paths: [1: dir + "/bad.jpg"], orientation: "vertical", maxSide: 400)
    #expect(!data.isEmpty)
}

@Test func laChooseParsesReply() throws {
    let (variants, paths) = try laThree()
    let a = laAssistant(#"{"choice":"B","reason":"лучше читается"}"#)
    #expect(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин")
        == AssistantChoice(index: 1, reason: "лучше читается"))
}

@Test func laReplyWithProseAroundJsonParsed() throws {
    let (variants, paths) = try laThree()
    let a = laAssistant("Вот ответ {не json} ```json\n{\"choice\": \"c\", \"reason\": \"ок\"}\n``` готово")
    #expect(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин")
        == AssistantChoice(index: 2, reason: "ок"))
}

@Test(arguments: [
    #"{"choice":"D","reason":"x"}"#, #"{"choice":"Z"}"#, #"{"choice":1}"#, #"{"choice":null}"#,
    #"{"choice":"AB"}"#, #"{"choice":""}"#, "[1, 2]", "no json", "", String?.none,
])
func laChoiceOutOfRangeReturnsNone(content: String?) throws {
    let (variants, paths) = try laThree()
    let a = laAssistant(content ?? NSNull())
    #expect(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин") == nil)
}

@Test func laReasonIsCleanText() throws {
    let (variants, paths) = try laThree()
    let a = laAssistant(#"{"choice":"A","reason":""# + String(repeating: "я\\n\\u0000", count: 300) + #""}"#)
    let choice = try #require(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин"))
    #expect(choice.index == 0)
    #expect(choice.reason.unicodeScalars.count <= 200)
    #expect(!choice.reason.contains("\n") && !choice.reason.contains("\u{0}"))
}

@Test func laNonStringReasonBecomesEmpty() throws {
    let (variants, paths) = try laThree()
    let a = laAssistant(#"{"choice":"A","reason":{"x":1}}"#)
    #expect(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин")
        == AssistantChoice(index: 0, reason: ""))
}

@Test func laMalformedResponseStructureReturnsNone() throws {
    let (variants, paths) = try laThree()
    let a = LayoutAssistant(
        baseURL: "http://x", model: "m",
        transport: { _ in try JSONSerialization.data(withJSONObject: ["choices": [Any]()]) })
    #expect(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "t") == nil)
}

@Test(arguments: [0, 1, 2])
func laTimeoutReturnsNone(kind: Int) throws {
    let (variants, paths) = try laThree()
    let a = LayoutAssistant(
        baseURL: "http://x", model: "m",
        transport: { _ in
            switch kind {
            case 0: throw URLError(.timedOut)
            case 1: throw URLError(.networkConnectionLost)
            default: throw LaFailure()
            }
        })
    #expect(a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "t") == nil)
}

@Test func laSingleVariantMakesNoRequest() throws {
    let calls = LaCalls()
    let a = laAssistant(#"{"choice":"A"}"#, calls: calls)
    let dir = try laTempDir()
    let paths = [1: laMakeJpeg(dir + "/a.jpg")]
    #expect(a.choose([laDraft(1, 1)], paths: paths, orientation: "vertical", storyTitle: "t") == nil)
    #expect(a.choose([], paths: paths, orientation: "vertical", storyTitle: "t") == nil)
    #expect(calls.requests.isEmpty)
}

@Test func laRequestCarriesImageAndTitle() throws {
    let (variants, paths) = try laThree()
    let calls = LaCalls()
    let a = laAssistant(#"{"choice":"A"}"#, calls: calls)
    _ = a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин")
    let first = try laTexts(calls.requests[0])
    #expect(first.url.hasSuffix("/chat/completions"))
    #expect(first.text.contains("Ужин"))
    #expect(first.image.hasPrefix("data:image/jpeg;base64,"))
    #expect(!first.text.contains("Пожелание"))
    _ = a.choose(variants, paths: paths, orientation: "vertical", storyTitle: "Ужин", wish: "больше лиц")
    let second = try laTexts(calls.requests[1])
    #expect(second.text.contains("Пожелание автора альбома: «больше лиц»"))
}

@Test func laConnectFalseWhenServerDown() {
    let a = LayoutAssistant(baseURL: "http://x", model: "m", transport: { _ in throw URLError(.cannotConnectToHost) })
    #expect(a.connect() == false)
}

@Test func laConnectTrueAndPicksModel() throws {
    let a = LayoutAssistant(
        baseURL: "http://x", model: "",
        transport: { _ in try JSONSerialization.data(withJSONObject: ["data": [["id": "vl-1"]]]) })
    #expect(a.connect() == true)
    #expect(a.model == "vl-1")
}

@Test func laConnectFalseWithoutModels() {
    let a = LayoutAssistant(
        baseURL: "http://x", model: "",
        transport: { _ in try JSONSerialization.data(withJSONObject: ["data": [Any]()]) })
    #expect(a.connect() == false)
}
