import CoreML
import Foundation
import Testing
@testable import AilbumCore

@Suite struct ModelStoreTests {
    @Test func availableMissing() {
        #expect(ModelStore.available("nope") == false)
    }

    @Test func nchwBGR() {
        let img = RGBImage(width: 2, height: 1, pixels: [10, 20, 30, 40, 50, 60])
        let t = Tensor.nchw(img, bgr: true, scale: 1, mean: [0, 0, 0])
        #expect(t.shape.map { $0.intValue } == [1, 3, 1, 2])
        #expect((0..<6).map { t[$0].floatValue } == [30, 60, 20, 50, 10, 40])
    }

    @Test func testMeanScale() {
        let img = RGBImage(width: 2, height: 1, pixels: [10, 20, 30, 40, 50, 60])
        let t = Tensor.nchw(img, bgr: true, scale: 0.5, mean: [1, 2, 3])
        // model channel 0 = B: (30-1)*.5, (60-1)*.5; ch1 = G: (20-2)*.5 ...; ch2 = R
        #expect((0..<6).map { t[$0].floatValue } == [14.5, 29.5, 9, 24, 3.5, 18.5])
        let r = Tensor.nchw(img, bgr: false, scale: 1, mean: [10, 0, 0])
        #expect((0..<2).map { r[$0].floatValue } == [0, 30])
    }

    @Test func testMissingModelThrows() throws {
        do {
            _ = try ModelStore.predict("nope", inputs: [:])
            Issue.record("expected throw")
        } catch let AilbumError.decode(msg) {
            #expect(msg.contains("nope"))
        }
    }

    @Test(.enabled(if: ModelStore.available("eye")))
    func testCompiledCache() throws {
        let a = try ModelStore.compiledURL("eye")
        let m1 = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date
        let b = try ModelStore.compiledURL("eye")
        let m2 = try FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as? Date
        #expect(a == b)
        #expect(m1 == m2)
    }
}
