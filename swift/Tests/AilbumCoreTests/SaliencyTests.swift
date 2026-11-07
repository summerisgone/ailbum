import Testing
import Foundation
@testable import AilbumCore

@Suite struct SaliencyTests {
    @Test func testDftBasics() {
        let (re, im) = Saliency.dft2([1, 0, 0], [0, 0, 0], width: 3, height: 1, inverse: false)
        #expect(re.map { ($0 * 1e9).rounded() / 1e9 } == [1, 1, 1])
        #expect(im.allSatisfy { abs($0) < 1e-12 })
    }

    @Test func testDftParity() {
        let w = 7, h = 5
        var re = [Double](), im = [Double]()
        for y in 0..<h { for x in 0..<w {
            let k = Double(y * 7 + x)
            re.append(sin(1.3 * k) + 0.5 * cos(0.7 * pow(k, 1.1)))
            im.append(cos(0.9 * k))
        } }
        let expRe: [Double] = [0.538979919369, 3.607784552702, -0.844672466078, -0.351507590185, -0.352514117689, -0.848751851754, 5.076798133667, -0.412877640664, 1.411406832804, -2.050132335425, -1.127676603195, -0.926691497542, -0.909277569298, 1.140776942539, 2.797436205561, 12.513077643977, -7.943147781346, -1.984753456218, -0.165883095528, 1.752265928325, 1.263453972702, 2.797641558039, 1.552508589923, 1.751690539844, -0.165849019731, -1.984316979091, -7.94209226534, 12.214832841184, -0.412007643596, 1.415181981281, -0.909076585544, -0.925896077818, -1.126478476669, -2.048299209129, 1.098066619925]
        let expIm: [Double] = [0.088686215027, 18.561851343287, 0.374364493849, 0.026882856415, -0.066553420742, -0.448758053329, 16.433847759126, -0.792236092956, -7.359996152567, 1.145069919805, 0.090002310544, -0.446162893907, -1.560981096453, 0.075822170127, -0.446529529239, 2.056903819488, -6.235077162312, -3.885533595389, -3.616799063363, -4.863468502994, 0.706017263468, 0.445883657643, -0.599234662975, 4.862470623649, 3.616012708625, 3.884877937653, 6.234608988786, -2.140871764372, 0.791567708216, 0.335228090009, 1.559135308706, 0.445169957739, -0.090441535313, -1.144671553921, 6.962911947669]
        let (fr, fi) = Saliency.dft2(re, im, width: w, height: h, inverse: false)
        for i in 0..<(w * h) {
            #expect(abs(fr[i] - expRe[i]) < 1e-9)
            #expect(abs(fi[i] - expIm[i]) < 1e-9)
        }
        let (br, bi) = Saliency.dft2(fr, fi, width: w, height: h, inverse: true)
        for i in 0..<(w * h) {
            #expect(abs(br[i] - re[i]) < 1e-9)
            #expect(abs(bi[i] - im[i]) < 1e-9)
        }
    }

    @Test func testDftPowerOfTwo() {
        let re = (0..<8).map { Double($0 * $0 % 5) }
        let (fr, fi) = Saliency.dft2(re, [Double](repeating: 0, count: 8), width: 4, height: 2, inverse: false)
        let (br, bi) = Saliency.dft2(fr, fi, width: 4, height: 2, inverse: true)
        for i in 0..<8 { #expect(abs(br[i] - re[i]) < 1e-12); #expect(abs(bi[i]) < 1e-12) }
        #expect(abs(fr[0] - re.reduce(0, +)) < 1e-12)
    }

    @Test func testQuantile() {
        #expect(abs(Saliency.quantile([4, 1, 3, 2], 0.82) - 3.46) < 1e-12)
        #expect(Saliency.quantile([5], 0.5) == 5)
    }

    @Test func testComponents() {
        // 6x3 mask: left blob of 2 px (diagonal, 8-connected) and right blob of 3 px
        let m: [Bool] = [
            true, false, false, false, true, true,
            false, true, false, false, false, true,
            false, false, false, false, false, false,
        ]
        let box = Saliency.largestComponent(m, width: 6, height: 3)
        #expect(box! == (x: 4, y: 0, w: 2, h: 2))
        let diag = Saliency.largestComponent([true, false, false, true], width: 2, height: 2)
        #expect(diag! == (x: 0, y: 0, w: 2, h: 2))
        #expect(Saliency.largestComponent([false, false], width: 2, height: 1) == nil)
    }

    @Test func testUniformImage() {
        let img = RGBImage(width: 50, height: 50, pixels: [UInt8](repeating: 128, count: 50 * 50 * 3))
        let (s, e) = Saliency.subject(img, maxSide: 800)
        #expect(s == nil)
        #expect(e == 0.0)
    }

    @Test func testSubjectParity() {
        let w = 120, h = 90
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            var v = (y * 37 + x * 91 + c * 13 + ((x * y) % 17) * 5) % 40 + 60
            if y >= 20 && y < 45 && x >= 70 && x < 95 { v = 240 }
            px[(y * w + x) * 3 + c] = UInt8(v)
        } } }
        let (s, e) = Saliency.subject(RGBImage(width: w, height: h, pixels: px), maxSide: 800)
        let subj = try! #require(s)
        #expect(subj.source == "saliency")
        let exp: [Double] = [0.55, 0.4444, 0.075, 0.1]
        for i in 0..<4 { #expect(abs(subj.bbox[i] - exp[i]) < 0.02) }
        #expect(abs(e - 0.6016645241867412) < 0.02)
    }
}

@Suite struct SaliencyPerfTests {
    @Test func testLargeImageSpeedAndFinite() {
        let w = 800, h = 533
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let inBox = x > 300 && x < 500 && y > 200 && y < 350
            let v = UInt8(inBox ? 230 : 40 + (x * 7 + y * 3) % 25)
            for c in 0..<3 { px[(y * w + x) * 3 + c] = v }
        } }
        let t0 = Date()
        let (subject, risk) = Saliency.subject(RGBImage(width: w, height: h, pixels: px), maxSide: 1000)
        let dt = Date().timeIntervalSince(t0)
        print("saliency 800x533 seconds:", dt)
        #expect(risk.isFinite && risk >= 0 && risk <= 1)
        #expect(subject != nil)
        #expect(dt < 30, "debug seconds \(dt)")  // release ~0.12 s; debug ~12 s
    }
}
