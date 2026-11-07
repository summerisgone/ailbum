import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import AilbumCore

private func writePhoto() -> String {
    let dir = NSTemporaryDirectory() + "t6-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/beach.jpg"
    var rgba = [UInt8](repeating: 255, count: 64 * 48 * 4)
    for i in 0..<(64 * 48) { rgba[i * 4] = 20; rgba[i * 4 + 1] = 40; rgba[i * 4 + 2] = 80 }
    let ctx = CGContext(data: &rgba, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return path
}

private func story(_ title: String, scenes: [String] = [], objects: [String] = []) -> StoryRecord {
    StoryRecord(storyId: 1, title: title, photoIds: ["photo-1"], startedAt: nil, endedAt: nil,
                representativePhotoId: "photo-1", sceneLabels: scenes, objectLabels: objects)
}

@Suite struct StoryNamingTests {
    @Test func storyNamerUsesLocalMultimodalResponse() throws {
        let photo = writePhoto()
        nonisolated(unsafe) var sawImage = false
        let namer = try StoryNamer(model: "test-vlm", transport: { req in
            if req.url!.absoluteString.hasSuffix("/models") {
                return Data(#"{"data":[{"id":"test-vlm"}]}"#.utf8)
            }
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let content = ((body["messages"] as! [[String: Any]])[0])["content"] as! [[String: Any]]
            sawImage = content.contains { ($0["type"] as? String) == "image_url" }
            return Data(#"{"choices":[{"message":{"content":"{\"title\":\"Ночная фотосессия на пляже\"}"}}]}"#.utf8)
        })
        let out = try namer.refine([story("Фотографии 03.08, 21:00", scenes: ["night", "beach"])],
                                   photoPaths: ["photo-1": photo])
        #expect(sawImage)
        #expect(out[0].title == "Ночная фотосессия на пляже")
        #expect(out[0].namingModel == "test-vlm")
        #expect(namer.backend == "lmstudio")
    }

    @Test func genericVlmTitleIsRejected() {
        #expect(StoryNamer.parseTitle(#"{"title":"Событие"}"#) == nil)
        #expect(StoryNamer.parseTitle(#"{"title":"Дай лайфхаки для дайвинга"}"#) == nil)
        #expect(StoryNamer.parseTitle("```json\n{\"title\":\"Прогулка у моря\"}\n```") == "Прогулка у моря")
    }

    @Test func unrelatedVlmTitleDoesNotReplaceSemanticAnchor() throws {
        let photo = writePhoto()
        let namer = try StoryNamer(model: "test-vlm", transport: { req in
            if req.url!.absoluteString.hasSuffix("/models") {
                return Data(#"{"data":[{"id":"test-vlm"}]}"#.utf8)
            }
            Issue.record("VLM must not be called for an informative title")
            throw URLError(.badServerResponse)
        })
        let s = story("Вечернее шоу и кальян", scenes: ["performance", "hookah", "hotel"], objects: ["food"])
        let out = try namer.refine([s], photoPaths: ["photo-1": photo])
        #expect(out[0].title == "Вечернее шоу и кальян")
        #expect(out[0].namingModel == nil)
    }

    @Test func parseTitle() {
        #expect(StoryNamer.parseTitle(#"{"title":"  «Закат на пляже»  "}"#) == "Закат на пляже")
        #expect(StoryNamer.parseTitle(#"{"title":"Закат   на\nпляже"}"#) == "Закат на пляже")
        #expect(StoryNamer.parseTitle(#"{"title":"ab"}"#) == nil)
        #expect(StoryNamer.parseTitle(#"{"title":"Что делать?"}"#) == nil)
        #expect(StoryNamer.parseTitle("no json") == nil)
        #expect(StoryNamer.parseTitle("{bad json}") == nil)
        #expect(StoryNamer.parseTitle(42) == nil)
        let parts: [Any] = [["text": #"{"title":"Поход "#], ["text": #"в горы"}"#]]
        #expect(StoryNamer.parseTitle(parts) == "Поход в горы")
    }

    @Test func evenlySpaced() {
        let p = ["a", "b", "c", "d", "e", "f"]
        #expect(StoryNamer.evenlySpaced(p, 4) == ["a", "c", "d", "f"])
        #expect(StoryNamer.evenlySpaced(p, 1) == ["d"])
        #expect(StoryNamer.evenlySpaced(["a"], 4) == ["a"])
    }

    @Test func lmStudioDownThrowsRussianError() throws {
        let namer = try StoryNamer(backend: "lmstudio", transport: { _ in throw URLError(.cannotConnectToHost) })
        #expect(throws: AilbumError.invalid("LM Studio недоступен. Запустите `lms server start` и загрузите VL-модель.")) {
            try namer.refine([story("Фотографии 03.08, 21:00")], photoPaths: [:])
        }
        #expect(namer.error != nil)
    }

    @Test func autoBackendFallsBackSilentlyAndOffIsNoop() throws {
        let stories = [story("Фотографии 03.08, 21:00")]
        let auto = try StoryNamer(transport: { _ in throw URLError(.cannotConnectToHost) })
        #expect(try auto.refine(stories, photoPaths: [:]) == stories)
        #expect(auto.backend == "rules")
        let off = try StoryNamer(backend: "off", transport: { _ in throw URLError(.cannotConnectToHost) })
        #expect(try off.refine(stories, photoPaths: [:]) == stories)
        #expect(off.error == nil)
    }
}
