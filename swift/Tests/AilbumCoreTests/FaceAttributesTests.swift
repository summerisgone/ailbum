import CoreML
import Foundation
import Testing
@testable import AilbumCore

@Suite struct FaceAttributesTests {
    static func image(_ w: Int, _ h: Int) -> RGBImage {
        RGBImage(width: w, height: h, pixels: (0..<(w * h * 3)).map { UInt8($0 % 251) })
    }

    /// Fake by default, real ModelStore when SUPERLITE_REAL=1.
    static func backend(eye: [Float] = [0.9, 0.1], expression: [Float] = [0, 0, 0, 1, 0, 0, 0]) -> FaceAttributesModel.Backend {
        if ProcessInfo.processInfo.environment["SUPERLITE_REAL"] == "1" { return .real }
        return .init(available: { _ in true }, predict: { name, _ in
            name == "eye" ? ["var_19": eye] : ["label": expression]
        })
    }

    @Test func testAsProbabilities() throws {
        #expect(try FaceAttributesModel.asProbabilities([0.2, 0.8]) == [0.2, 0.8])
        let p = try FaceAttributesModel.asProbabilities([0, Float(log(3.0))])
        #expect(abs(p[0] - 0.25) < 1e-6 && abs(p[1] - 0.75) < 1e-6)
    }

    @Test func testEmptyThrows() {
        #expect(throws: AilbumError.self) { try FaceAttributesModel.asProbabilities([]) }
    }

    @Test func testSquareCropEdges() throws {
        let crop = try #require(FaceAttributesModel.squareCrop(Self.image(112, 112), center: (2, 2), side: 16))
        #expect(crop.width == 10 && crop.height == 10)
        #expect(FaceAttributesModel.bilinear(crop, width: 32, height: 32).width == 32)
        #expect(FaceAttributesModel.squareCrop(Self.image(4, 4), center: (50, 50), side: 16) == nil)
    }

    @Test func testRounding() {
        #expect(FaceAttributesModel.round4(0.123456) == 0.1235)
        #expect(FaceAttributesModel.round4(0.8) == 0.8)
    }

    @Test func testMissingModels() throws {
        let none = FaceAttributesModel.Backend(available: { _ in false }, predict: { _, _ in [:] })
        #expect(try FaceAttributesModel.classify(Self.image(112, 112), backend: none) == FaceAttributes())
    }

    @Test func testClassifyWithModels() throws {
        let a = try FaceAttributesModel.classify(Self.image(112, 112), backend: Self.backend())
        #expect(a.leftEye != nil && a.rightEye != nil)
        #expect(a.expression != nil)
        #expect(a.expressionScores?.count == 7)
    }

    @Test func testFakeValues() throws {
        if ProcessInfo.processInfo.environment["SUPERLITE_REAL"] == "1" { return }
        let a = try FaceAttributesModel.classify(Self.image(112, 112), backend: Self.backend(eye: [0.3, 0.7]))
        #expect(a.leftEye == "closed" && a.rightEye == "closed")
        #expect(a.leftEyeOpenProbability == 0.3)
        #expect(a.expression == "happy" && a.expressionConfidence == 1)
    }
}
