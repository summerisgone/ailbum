public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct Region: Equatable, Sendable {
    public var bbox: Rect
    public var weight: Double
    public var hard: Bool
    public var kind: String

    public init(bbox: Rect, weight: Double, hard: Bool, kind: String) {
        self.bbox = bbox
        self.weight = weight
        self.hard = hard
        self.kind = kind
    }
}

public struct Cell: Equatable, Sendable {
    public var index: Int
    public var rect: Rect
    public var safe: Rect
    public var spineBand: Rect?

    public init(index: Int, rect: Rect, safe: Rect, spineBand: Rect?) {
        self.index = index
        self.rect = rect
        self.safe = safe
        self.spineBand = spineBand
    }
}

public struct CropResult: Equatable, Sendable {
    public var rect: Rect
    public var fit: Double
    public var violations: [String]

    public init(rect: Rect, fit: Double, violations: [String]) {
        self.rect = rect
        self.fit = fit
        self.violations = violations
    }
}

public struct LayoutParams: Equatable, Sendable {
    public var orientation: String
    public var spreadCount: Int
    public var minPhotos: Int
    public var maxPhotos: Int
    public var assistant: String
    public var prompt: String

    public init(
        orientation: String, spreadCount: Int, minPhotos: Int, maxPhotos: Int,
        assistant: String = "auto", prompt: String = ""
    ) {
        self.orientation = orientation
        self.spreadCount = spreadCount
        self.minPhotos = minPhotos
        self.maxPhotos = maxPhotos
        self.assistant = assistant
        self.prompt = prompt
    }
}

public struct PhotoFacts: Equatable, Sendable {
    public var imageId: Int
    public var aspect: Double
    public var unitKey: String
    public var storyId: Int?
    public var takenAt: String?
    public var rank: Double
    public var selected: Bool
    public var regions: [Region]

    public init(
        imageId: Int, aspect: Double, unitKey: String, storyId: Int?, takenAt: String?,
        rank: Double, selected: Bool, regions: [Region]
    ) {
        self.imageId = imageId
        self.aspect = aspect
        self.unitKey = unitKey
        self.storyId = storyId
        self.takenAt = takenAt
        self.rank = rank
        self.selected = selected
        self.regions = regions
    }
}

public struct PlacementDraft: Equatable, Sendable {
    public var cellIndex: Int
    public var imageId: Int
    public var crop: Rect
    public var fit: Double
    public var warnings: [String]
    public var replacedImageId: Int?

    public init(
        cellIndex: Int, imageId: Int, crop: Rect, fit: Double, warnings: [String],
        replacedImageId: Int?
    ) {
        self.cellIndex = cellIndex
        self.imageId = imageId
        self.crop = crop
        self.fit = fit
        self.warnings = warnings
        self.replacedImageId = replacedImageId
    }
}

public struct SpreadDraft: Equatable, Sendable {
    public var templateId: String
    public var storyIds: [Int]
    public var placements: [PlacementDraft]
    public var score: Double
    public var warnings: [String]
    public var alternatives: [SpreadDraft]
    public var assistantReason: String?

    public init(
        templateId: String, storyIds: [Int], placements: [PlacementDraft], score: Double,
        warnings: [String] = [], alternatives: [SpreadDraft] = [], assistantReason: String? = nil
    ) {
        self.templateId = templateId
        self.storyIds = storyIds
        self.placements = placements
        self.score = score
        self.warnings = warnings
        self.alternatives = alternatives
        self.assistantReason = assistantReason
    }
}
