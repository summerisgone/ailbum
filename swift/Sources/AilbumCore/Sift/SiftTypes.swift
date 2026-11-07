public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public struct ScaleSpace {
    public let firstOctave: Int
    public let layers: Int
    public let sigma: Double
    public var gaussians: [[GrayImage]]
    public var dogs: [[GrayImage]]

    public init(firstOctave: Int, layers: Int, sigma: Double, gaussians: [[GrayImage]], dogs: [[GrayImage]]) {
        self.firstOctave = firstOctave
        self.layers = layers
        self.sigma = sigma
        self.gaussians = gaussians
        self.dogs = dogs
    }
}

public struct SiftKeypoint: Equatable {
    public var x: Float
    public var y: Float
    public var size: Float
    public var angle: Float
    public var response: Float
    public var octave: Int
    public var layer: Int
    public var subLayer: Float

    public init(x: Float, y: Float, size: Float, angle: Float, response: Float, octave: Int, layer: Int, subLayer: Float) {
        self.x = x
        self.y = y
        self.size = size
        self.angle = angle
        self.response = response
        self.octave = octave
        self.layer = layer
        self.subLayer = subLayer
    }
}

public struct GeometricFeatures {
    public var keypoints: [SIMD2<Float>]
    public var descriptors: [Float]
    public let width: Int
    public let height: Int

    public init(keypoints: [SIMD2<Float>], descriptors: [Float], width: Int, height: Int) {
        self.keypoints = keypoints
        self.descriptors = descriptors
        self.width = width
        self.height = height
    }
}

public struct PhotoFeatures {
    public var phash: [Bool]
    public var histogram: [Float]
    public var geometric: GeometricFeatures?

    public init(phash: [Bool], histogram: [Float], geometric: GeometricFeatures?) {
        self.phash = phash
        self.histogram = histogram
        self.geometric = geometric
    }
}

public struct GeometricSimilarity: Equatable {
    public var score: Double
    public var mutualMatches: Int
    public var inliers: Int
    public var inlierRatio: Double
    public var coverageLeft: Double
    public var coverageRight: Double

    public static let empty = GeometricSimilarity(score: 0, mutualMatches: 0, inliers: 0, inlierRatio: 0, coverageLeft: 0, coverageRight: 0)

    public init(score: Double, mutualMatches: Int, inliers: Int, inlierRatio: Double, coverageLeft: Double, coverageRight: Double) {
        self.score = score
        self.mutualMatches = mutualMatches
        self.inliers = inliers
        self.inlierRatio = inlierRatio
        self.coverageLeft = coverageLeft
        self.coverageRight = coverageRight
    }
}
