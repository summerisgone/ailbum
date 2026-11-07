import Foundation

public struct EyeStateRecord: Equatable {
    public var left: String?
    public var right: String?
    public var leftOpenProbability: Double?
    public var rightOpenProbability: Double?
    public var bothOpen: Bool?

    public init(left: String? = nil, right: String? = nil, leftOpenProbability: Double? = nil,
                rightOpenProbability: Double? = nil, bothOpen: Bool? = nil) {
        self.left = left
        self.right = right
        self.leftOpenProbability = leftOpenProbability
        self.rightOpenProbability = rightOpenProbability
        self.bothOpen = bothOpen
    }
}

public struct ExpressionRecord: Equatable {
    public var label: String
    public var confidence: Double
    public var smileProbability: Double
    public var scores: [String: Double]

    public init(label: String, confidence: Double, smileProbability: Double, scores: [String: Double]) {
        self.label = label
        self.confidence = confidence
        self.smileProbability = smileProbability
        self.scores = scores
    }
}

public struct FaceRecord: Equatable {
    public var faceId: String
    public var bbox: SIMD4<Int>
    public var confidence: Double
    public var personCluster: Int?
    public var personId: Int?
    public var databaseId: Int?
    public var embedding: [Float]?
    public var eyes: EyeStateRecord?
    public var expression: ExpressionRecord?

    public init(faceId: String, bbox: SIMD4<Int>, confidence: Double, personCluster: Int? = nil,
                personId: Int? = nil, databaseId: Int? = nil, embedding: [Float]? = nil,
                eyes: EyeStateRecord? = nil, expression: ExpressionRecord? = nil) {
        self.faceId = faceId
        self.bbox = bbox
        self.confidence = confidence
        self.personCluster = personCluster
        self.personId = personId
        self.databaseId = databaseId
        self.embedding = embedding
        self.eyes = eyes
        self.expression = expression
    }
}

public struct PersonRecord: Equatable {
    public var clusterId: Int
    public var faceIds: [String]
    public var photoIds: [String]
    public var embeddingModel: String
    public var centroid: [Float]
    public var personId: Int?
    public var publicId: String?
    public var name: String?

    public init(clusterId: Int, faceIds: [String], photoIds: [String], embeddingModel: String,
                centroid: [Float], personId: Int? = nil, publicId: String? = nil, name: String? = nil) {
        self.clusterId = clusterId
        self.faceIds = faceIds
        self.photoIds = photoIds
        self.embeddingModel = embeddingModel
        self.centroid = centroid
        self.personId = personId
        self.publicId = publicId
        self.name = name
    }
}

public struct StoryRecord: Equatable {
    public var storyId: Int
    public var title: String
    public var photoIds: [String]
    public var startedAt: String?
    public var endedAt: String?
    public var representativePhotoId: String
    public var sceneLabels: [String]
    public var objectLabels: [String]
    public var namingModel: String?

    public init(storyId: Int, title: String, photoIds: [String], startedAt: String?, endedAt: String?,
                representativePhotoId: String, sceneLabels: [String] = [], objectLabels: [String] = [],
                namingModel: String? = nil) {
        self.storyId = storyId
        self.title = title
        self.photoIds = photoIds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.representativePhotoId = representativePhotoId
        self.sceneLabels = sceneLabels
        self.objectLabels = objectLabels
        self.namingModel = namingModel
    }
}

public struct PhotoRecord {
    public var photoId: String
    public var path: String
    public var width: Int
    public var height: Int
    public var takenAt: String?
    public var sharpness: Double
    public var exposure: Double
    public var quality: Double
    public var isBlurry: Bool
    public var composition: CompositionRecord?
    public var color: ColorRecord?
    public var semantics: SemanticRecord?
    public var similarCluster: Int?
    public var storyId: Int?
    public var selected: Bool
    public var faces: [FaceRecord]
    public var error: String?

    public init(photoId: String, path: String, width: Int, height: Int, takenAt: String?,
                sharpness: Double, exposure: Double, quality: Double, isBlurry: Bool,
                composition: CompositionRecord? = nil, color: ColorRecord? = nil,
                semantics: SemanticRecord? = nil, similarCluster: Int? = nil, storyId: Int? = nil,
                selected: Bool = false, faces: [FaceRecord] = [], error: String? = nil) {
        self.photoId = photoId
        self.path = path
        self.width = width
        self.height = height
        self.takenAt = takenAt
        self.sharpness = sharpness
        self.exposure = exposure
        self.quality = quality
        self.isBlurry = isBlurry
        self.composition = composition
        self.color = color
        self.semantics = semantics
        self.similarCluster = similarCluster
        self.storyId = storyId
        self.selected = selected
        self.faces = faces
        self.error = error
    }
}

public struct PipelineConfig {
    public var sharpnessThreshold: Double = 100.0
    public var photoHashDistance: Int = 12
    public var photoHistSimilarity: Double = 0.72
    public var photoGeometricSimilarity: Double? = 0.55
    public var geometricMaxFeatures: Int = 4000
    public var geometricNeighborWindow: Int = 12
    public var geometricTimeWindowMinutes: Int = 15
    public var faceSimilarity: Double? = nil
    public var minFaceSize: Int = 40
    public var minAttributeFaceSize: Int = 64
    public var maxImageSide: Int = 1600
    public var faceBackend: String = "auto"
    public var semanticBackend: String = "auto"
    public var clipModel: String = "openai/clip-vit-base-patch32"
    public var semanticThreshold: Double = 0.15
    public var semanticTopK: Int = 3
    public var semanticBatchSize: Int = 8
    public var semanticDevice: String = "auto"
    public var storyGapMinutes: Int = 120
    public var storyContinuityMinutes: Int = 360
    public var storyMaxDurationHours: Int = 12
    public var storySemanticBreakMinutes: Int = 30
    public var storyNamingBackend: String = "auto"
    public var lmstudioUrl: String = "http://127.0.0.1:1234/v1"
    public var lmstudioModel: String = "qwen/qwen3-vl-2b"
    public var storyVlmImages: Int = 4
    public var storyVlmTimeout: Double = 90.0
    public var modelsDir: URL = URL(fileURLWithPath: "models")
    public var featureCache: Bool = true
    public var featureCacheDir: URL? = nil

    public init() {}
}

public struct ImageMetadata: Equatable {
    public var path: String
    public var sourceRoot: String
    public var relativePath: String
    public var fileName: String
    public var `extension`: String
    public var fileSizeBytes: Int
    public var modifiedAt: String
    public var createdAt: String?
    public var sha256: String
    public var mimeType: String?
    public var imageFormat: String?
    public var colorMode: String?
    public var width: Int?
    public var height: Int?
    public var frameCount: Int?
    public var orientation: Int?
    public var takenAt: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var software: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    public var exif: JSONValue
    public var containerMetadata: JSONValue
    public var extractionError: String?

    public init(path: String, sourceRoot: String, relativePath: String, fileName: String,
                extension ext: String, fileSizeBytes: Int, modifiedAt: String, createdAt: String? = nil,
                sha256: String, mimeType: String? = nil, imageFormat: String? = nil,
                colorMode: String? = nil, width: Int? = nil, height: Int? = nil, frameCount: Int? = nil,
                orientation: Int? = nil, takenAt: String? = nil, cameraMake: String? = nil,
                cameraModel: String? = nil, lensModel: String? = nil, software: String? = nil,
                gpsLatitude: Double? = nil, gpsLongitude: Double? = nil, gpsAltitude: Double? = nil,
                exif: JSONValue = [:], containerMetadata: JSONValue = [:], extractionError: String? = nil) {
        self.path = path
        self.sourceRoot = sourceRoot
        self.relativePath = relativePath
        self.fileName = fileName
        self.extension = ext
        self.fileSizeBytes = fileSizeBytes
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.sha256 = sha256
        self.mimeType = mimeType
        self.imageFormat = imageFormat
        self.colorMode = colorMode
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.orientation = orientation
        self.takenAt = takenAt
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.software = software
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.gpsAltitude = gpsAltitude
        self.exif = exif
        self.containerMetadata = containerMetadata
        self.extractionError = extractionError
    }
}

public struct StoryPhoto: Equatable {
    public var photoId: String
    public var takenAt: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var people: Set<String>
    public var scenes: [TagRecord]
    public var objects: [TagRecord]
    public var embedding: [Float]?
    public var quality: Double
    public var isBlurry: Bool

    public init(photoId: String, takenAt: String?, gpsLatitude: Double? = nil, gpsLongitude: Double? = nil,
                people: Set<String> = [], scenes: [TagRecord] = [], objects: [TagRecord] = [],
                embedding: [Float]? = nil, quality: Double = 0.0, isBlurry: Bool = false) {
        self.photoId = photoId
        self.takenAt = takenAt
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.people = people
        self.scenes = scenes
        self.objects = objects
        self.embedding = embedding
        self.quality = quality
        self.isBlurry = isBlurry
    }
}
