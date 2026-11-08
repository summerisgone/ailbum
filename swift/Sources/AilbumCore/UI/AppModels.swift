import Foundation

/// Codable mirrors of desktop/src/types.ts. Property names are the snake_case keys of the bridge JSON.
/// Unknown keys are ignored by the synthesized decoders.
public enum AppModels {
    public static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

public enum Availability: String, Codable, Equatable, Sendable { case present, missing, archived }
public enum AlbumPurpose: String, Codable, Equatable, Sendable { case photobook_demo, print }
public enum AlbumStatus: String, Codable, Equatable, Sendable { case draft, ordered, archived }
public enum LayoutOrientation: String, Codable, Equatable, Sendable { case vertical, horizontal }
public enum AssistantMode: String, Codable, Equatable, Sendable { case auto, off }
public enum EyeState: String, Codable, Equatable, Sendable { case open, closed }

public struct MainSubject: Codable, Equatable, Sendable {
    public var bbox: [Double]
    public var center: [Double]
    public var source: String
}

public struct LabelTag: Codable, Equatable, Sendable {
    public var label: String
    public var confidence: Double
}

public struct Photo: Codable, Equatable, Sendable {
    public var id: Int
    public var path: String
    public var media_path: String?
    public var availability: Availability
    public var file_name: String
    public var width: Int?
    public var height: Int?
    public var orientation: Int?
    public var taken_at: String?
    public var modified_at: String
    public var quality: Double?
    public var sharpness: Double?
    public var exposure: Double?
    public var aesthetic_score: Double?
    public var composition_score: Double?
    public var rule_of_thirds: Double?
    public var frame_occupancy: Double?
    public var negative_space: Double?
    public var crop_risk: Double?
    public var color_balance: Double?
    public var color_harmony: Double?
    public var main_subject: MainSubject?
    public var scene_tags: [LabelTag]
    public var object_tags: [LabelTag]
    public var is_blurry: Bool
    public var similar_cluster: Int?
    public var story_id: Int?
    public var story_title: String?
    public var auto_selected: Bool
    public var face_count: Int
    public var people_count: Int
    public var closed_eyes_count: Int
    public var smiling_faces_count: Int
    public var people_names: [String]
    public var favorite: Bool
    public var selection_position: Int?
}

public struct AnalysisRun: Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var started_at: String
    public var completed_at: String
    public var face_backend: String
    public var summary: [String: JSONValue]
}

public struct Story: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var started_at: String?
    public var ended_at: String?
    public var representative_image_id: Int?
    public var photo_count: Int
    public var naming_model: String?
}

public struct Album: Codable, Equatable, Sendable {
    public var id: Int
    public var public_id: String
    public var title: String
    public var purpose: AlbumPurpose
    public var status: AlbumStatus
    public var target_count: Int
    public var run_id: String?
    public var sources: [String]
    public var photo_count: Int
    public var ordered_at: String?
    public var archived_at: String?
    public var updated_at: String
}

public struct Usage: Codable, Equatable, Sendable {
    public struct Images: Codable, Equatable, Sendable {
        public var present: Int
        public var missing: Int
        public var archived: Int
    }
    public var database_bytes: Int
    public var proxies_bytes: Int
    public var feature_cache_bytes: Int
    public var images: Images
}

public struct BlockedImage: Codable, Equatable, Sendable {
    public var image_id: Int
    public var reason: String
}

public enum ArchiveResult: Codable, Equatable, Sendable {
    case cancelled
    case needsExport(blocked: [BlockedImage])
    case archived(archived: Int, blocked: [BlockedImage], failed: [String])

    private enum Keys: String, CodingKey { case cancelled, needsExport, blocked, archived, failed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .cancelled) == true {
            self = .cancelled
        } else if try c.decodeIfPresent(Bool.self, forKey: .needsExport) == true {
            self = .needsExport(blocked: try c.decodeIfPresent([BlockedImage].self, forKey: .blocked) ?? [])
        } else {
            self = .archived(
                archived: try c.decode(Int.self, forKey: .archived),
                blocked: try c.decodeIfPresent([BlockedImage].self, forKey: .blocked) ?? [],
                failed: try c.decodeIfPresent([String].self, forKey: .failed) ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .cancelled:
            try c.encode(true, forKey: .cancelled)
        case .needsExport(let blocked):
            try c.encode(true, forKey: .needsExport)
            try c.encode(blocked, forKey: .blocked)
        case .archived(let archived, let blocked, let failed):
            try c.encode(archived, forKey: .archived)
            try c.encode(blocked, forKey: .blocked)
            try c.encode(failed, forKey: .failed)
            try c.encode(false, forKey: .needsExport)
        }
    }
}

public struct Library: Codable, Equatable, Sendable {
    public var database: String
    public var album: Album?
    public var albums: [Album]
    public var run: AnalysisRun?
    public var target_count: Int
    public var selected_count: Int
    public var stories: [Story]
    public var photos: [Photo]
}

public struct DatabaseSummary: Codable, Equatable, Sendable {
    public var images: Int
    public var available: Int
    public var unique_files: Int
    public var bytes: Int
    public var with_gps: Int
    public var with_taken_at: Int
    public var analysis_runs: Int
    public var faces: Int
    public var linked_faces: Int
    public var people: Int
    public var stories: Int
}

/// Encodes to the exact keys LayoutWizard.tsx sends; nil optionals are omitted.
public struct AppLayoutParams: Codable, Equatable, Sendable {
    public var orientation: LayoutOrientation
    public var spread_count: Int
    public var min_photos: Int
    public var max_photos: Int
    public var assistant: AssistantMode?
    public var prompt: String?

    public init(orientation: LayoutOrientation, spread_count: Int, min_photos: Int, max_photos: Int,
                assistant: AssistantMode? = nil, prompt: String? = nil) {
        self.orientation = orientation
        self.spread_count = spread_count
        self.min_photos = min_photos
        self.max_photos = max_photos
        self.assistant = assistant
        self.prompt = prompt
    }
}

public struct LayoutAllocation: Codable, Equatable, Sendable {
    public var story_ids: [Int]
    public var title: String
    public var spreads: Int
    public var units: Int
}

public struct LayoutPreflight: Codable, Equatable, Sendable {
    public var pool_count: Int
    public var unit_count: Int
    public var story_count: Int
    public var min_needed: Int
    public var max_used: Int
    public var allocation: [LayoutAllocation]
    public var errors: [String]
    public var warnings: [String]
}

public struct LayoutRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}

public struct LayoutTemplateCell: Codable, Equatable, Sendable {
    public var index: Int
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}

public struct LayoutTemplateInfo: Codable, Equatable, Sendable {
    public var id: String
    public var photo_count: Int
    public var cells: [LayoutTemplateCell]
}

public struct LayoutAlternativePlacement: Codable, Equatable, Sendable {
    public var spread_id: Int
    public var position: Int
    public var cell_index: Int
}

public struct LayoutAlternative: Codable, Equatable, Sendable {
    public var image_id: Int
    public var fit: Double
    public var warnings: [String]
    public var in_selection: Bool
    public var placed: LayoutAlternativePlacement?
    public var similar: Bool
}

public struct LayoutVariantCell: Codable, Equatable, Sendable {
    public var index: Int
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var image_id: Int
    public var crop: LayoutRect
}

public struct LayoutVariant: Codable, Equatable, Sendable {
    public var template_id: String
    public var score: Double
    public var image_ids: [Int]
    public var cells: [LayoutVariantCell]
}

public struct LayoutPromptInfo: Codable, Equatable, Sendable {
    public var weights: [String: Double]
    public var labels: [String]
}

public struct LayoutPlacement: Codable, Equatable, Sendable {
    public var image_id: Int
    public var crop: LayoutRect
    public var fit: Double
    public var warnings: [String]
    public var replaced_image_id: Int?
}

public struct LayoutCell: Codable, Equatable, Sendable {
    public var index: Int
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var crosses_spine: Bool
    public var placement: LayoutPlacement?
}

public struct LayoutSpread: Codable, Equatable, Sendable {
    public var id: Int
    public var position: Int
    public var template_id: String
    public var story_ids: [Int]
    public var story_title: String
    public var warnings: [String]
    public var assistant_reason: String?
    public var cells: [LayoutCell]
}

public struct LayoutUnplaced: Codable, Equatable, Sendable {
    public var image_id: Int
    public var reason: String
}

public struct LayoutFormat: Codable, Equatable, Sendable {
    public var spread_w_mm: Double
    public var spread_h_mm: Double
    public var bleed_mm: Double
    public var safe_mm: Double
}

public struct Layout: Codable, Equatable, Sendable {
    public var id: Int
    public var run_id: String?
    public var album_id: Int
    public var orientation: LayoutOrientation
    public var spread_count: Int
    public var min_photos: Int
    public var max_photos: Int
    public var stale: Bool
    public var assistant_model: String?
    public var warnings: [String]
    public var unplaced: [LayoutUnplaced]
    public var format: LayoutFormat
    public var spreads: [LayoutSpread]
}

public struct FavoriteResult: Codable, Equatable, Sendable {
    public var album_id: Int
    public var image_id: Int
    public var favorite: Bool
    public var selected_count: Int
}

public struct PersonSummary: Codable, Equatable, Sendable {
    public var id: Int
    public var public_id: String
    public var name: String?
    public var embedding_model: String
    public var face_count: Int
    public var photo_count: Int
    public var cover_face_id: Int?
}

public struct Face: Codable, Equatable, Sendable {
    public var id: Int
    public var run_id: String
    public var face_id: String
    public var face_index: Int
    public var image_id: Int
    public var bbox_x: Double
    public var bbox_y: Double
    public var bbox_width: Double
    public var bbox_height: Double
    public var confidence: Double
    public var person_id: Int?
    public var embedding_model: String?
    public var left_eye_state: EyeState?
    public var right_eye_state: EyeState?
    public var both_eyes_open: Bool?
    public var expression: String?
    public var expression_confidence: Double?
    public var smile_probability: Double?
    public var path: String
    public var file_name: String
    public var taken_at: String?
    public var orientation: Int?
}

public struct PeopleLibrary: Codable, Equatable, Sendable {
    public var database: String
    public var people: [PersonSummary]
    public var unassigned_count: Int
    public var total_faces: Int
}

public struct FacePerson: Codable, Equatable, Sendable {
    public var id: Int
    public var public_id: String
    public var name: String?
    public var embedding_model: String
}

public struct FaceCollection: Codable, Equatable, Sendable {
    public var person: FacePerson?
    public var faces: [Face]
}
