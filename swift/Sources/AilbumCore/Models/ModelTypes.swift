public struct FaceDetection {
    public var bbox: (x: Int, y: Int, w: Int, h: Int)
    public var confidence: Float
    public var landmarks: [SIMD2<Float>]

    public init(bbox: (x: Int, y: Int, w: Int, h: Int), confidence: Float, landmarks: [SIMD2<Float>]) {
        self.bbox = bbox
        self.confidence = confidence
        self.landmarks = landmarks
    }
}

public struct FaceAttributes: Equatable {
    public var leftEye: String?
    public var rightEye: String?
    public var leftEyeOpenProbability: Double?
    public var rightEyeOpenProbability: Double?
    public var expression: String?
    public var expressionConfidence: Double?
    public var expressionScores: [String: Double]?

    public init(
        leftEye: String? = nil,
        rightEye: String? = nil,
        leftEyeOpenProbability: Double? = nil,
        rightEyeOpenProbability: Double? = nil,
        expression: String? = nil,
        expressionConfidence: Double? = nil,
        expressionScores: [String: Double]? = nil
    ) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftEyeOpenProbability = leftEyeOpenProbability
        self.rightEyeOpenProbability = rightEyeOpenProbability
        self.expression = expression
        self.expressionConfidence = expressionConfidence
        self.expressionScores = expressionScores
    }

    public var bothEyesOpen: Bool? {
        guard let leftEye, let rightEye else { return nil }
        return leftEye == "open" && rightEye == "open"
    }

    public var smileProbability: Double? {
        expressionScores?["happy"]
    }
}

public struct DetectedObject: Equatable {
    public var label: String
    public var score: Float
    public var bbox: SIMD4<Float>

    public init(label: String, score: Float, bbox: SIMD4<Float>) {
        self.label = label
        self.score = score
        self.bbox = bbox
    }
}

public struct TagRecord: Equatable {
    public var label: String
    public var confidence: Double

    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

public struct SemanticRecord {
    public var aestheticScore: Double?
    public var model: String?
    public var scenes: [TagRecord]
    public var objects: [TagRecord]
    public var embedding: [Float]?

    public init(
        aestheticScore: Double?,
        model: String?,
        scenes: [TagRecord] = [],
        objects: [TagRecord] = [],
        embedding: [Float]? = nil
    ) {
        self.aestheticScore = aestheticScore
        self.model = model
        self.scenes = scenes
        self.objects = objects
        self.embedding = embedding
    }
}

public struct SubjectRecord: Equatable {
    public var bbox: SIMD4<Double>
    public var center: SIMD2<Double>
    public var source: String

    public init(bbox: SIMD4<Double>, center: SIMD2<Double>, source: String) {
        self.bbox = bbox
        self.center = center
        self.source = source
    }
}

public struct CompositionRecord: Equatable {
    public var ruleOfThirds: Double
    public var frameOccupancy: Double
    public var negativeSpace: Double
    public var cropRisk: Double
    public var score: Double
    public var mainSubject: SubjectRecord?

    public init(
        ruleOfThirds: Double,
        frameOccupancy: Double,
        negativeSpace: Double,
        cropRisk: Double,
        score: Double,
        mainSubject: SubjectRecord? = nil
    ) {
        self.ruleOfThirds = ruleOfThirds
        self.frameOccupancy = frameOccupancy
        self.negativeSpace = negativeSpace
        self.cropRisk = cropRisk
        self.score = score
        self.mainSubject = mainSubject
    }
}

public struct ColorRecord: Equatable {
    public var balance: Double
    public var harmony: Double
    public var meanSaturation: Double

    public init(balance: Double, harmony: Double, meanSaturation: Double) {
        self.balance = balance
        self.harmony = harmony
        self.meanSaturation = meanSaturation
    }
}
