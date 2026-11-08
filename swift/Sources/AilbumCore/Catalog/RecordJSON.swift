import Foundation

private func opt(_ v: Int?) -> JSONValue { v.map { .int($0) } ?? .null }
private func opt(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }
private func opt(_ v: Double?) -> JSONValue { v.map { .double($0) } ?? .null }
private func opt(_ v: Bool?) -> JSONValue { v.map { .bool($0) } ?? .null }

extension EyeStateRecord {
    func toJSON() -> JSONValue {
        [
            "left": opt(left), "right": opt(right),
            "left_open_probability": opt(leftOpenProbability),
            "right_open_probability": opt(rightOpenProbability),
            "both_open": opt(bothOpen),
        ]
    }
}

extension ExpressionRecord {
    func toJSON() -> JSONValue {
        [
            "label": .string(label), "confidence": .double(confidence),
            "smile_probability": .double(smileProbability),
            "scores": .object(scores.mapValues { .double($0) }),
        ]
    }
}

extension TagRecord {
    func toJSON() -> JSONValue { ["label": .string(label), "confidence": .double(confidence)] }
}

extension SemanticRecord {
    /// Python `asdict` minus `embedding` (as in `PhotoRecord.to_dict`).
    func toJSON() -> JSONValue {
        [
            "aesthetic_score": opt(aestheticScore), "model": opt(model),
            "scenes": .array(scenes.map { $0.toJSON() }),
            "objects": .array(objects.map { $0.toJSON() }),
        ]
    }
}

extension SubjectRecord {
    func toJSON() -> JSONValue {
        [
            "bbox": .array([bbox.x, bbox.y, bbox.z, bbox.w].map { .double($0) }),
            "center": .array([center.x, center.y].map { .double($0) }),
            "source": .string(source),
        ]
    }
}

extension CompositionRecord {
    func toJSON() -> JSONValue {
        [
            "rule_of_thirds": .double(ruleOfThirds), "frame_occupancy": .double(frameOccupancy),
            "negative_space": .double(negativeSpace), "crop_risk": .double(cropRisk),
            "score": .double(score), "main_subject": mainSubject?.toJSON() ?? .null,
        ]
    }
}

extension ColorRecord {
    func toJSON() -> JSONValue {
        ["balance": .double(balance), "harmony": .double(harmony), "mean_saturation": .double(meanSaturation)]
    }
}

extension FaceRecord {
    func toJSON() -> JSONValue {
        [
            "face_id": .string(faceId),
            "bbox": .array([bbox.x, bbox.y, bbox.z, bbox.w].map { .int($0) }),
            "confidence": .double(confidence),
            "person_cluster": opt(personCluster), "person_id": opt(personId),
            "database_id": opt(databaseId),
            "eyes": eyes?.toJSON() ?? .null, "expression": expression?.toJSON() ?? .null,
        ]
    }
}

extension PersonRecord {
    func toJSON() -> JSONValue {
        [
            "person_cluster": .int(clusterId), "person_id": opt(personId),
            "public_id": opt(publicId), "name": opt(name),
            "faces": .array(faceIds.map { .string($0) }),
            "photos": .array(photoIds.map { .string($0) }),
        ]
    }
}

extension StoryRecord {
    func toJSON() -> JSONValue {
        [
            "story_id": .int(storyId), "title": .string(title),
            "photo_ids": .array(photoIds.map { .string($0) }),
            "started_at": opt(startedAt), "ended_at": opt(endedAt),
            "representative_photo_id": .string(representativePhotoId),
            "scene_labels": .array(sceneLabels.map { .string($0) }),
            "object_labels": .array(objectLabels.map { .string($0) }),
            "naming_model": opt(namingModel),
        ]
    }
}

extension PhotoRecord {
    func toJSON() -> JSONValue {
        [
            "photo_id": .string(photoId), "path": .string(path),
            "width": .int(width), "height": .int(height), "taken_at": opt(takenAt),
            "sharpness": .double(sharpness), "exposure": .double(exposure),
            "quality": .double(quality), "is_blurry": .bool(isBlurry),
            "composition": composition?.toJSON() ?? .null, "color": color?.toJSON() ?? .null,
            "semantics": semantics?.toJSON() ?? .null,
            "similar_cluster": opt(similarCluster), "story_id": opt(storyId),
            "selected": .bool(selected), "faces": .array(faces.map { $0.toJSON() }),
            "error": opt(error),
        ]
    }
}
