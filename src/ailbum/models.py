from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class EyeStateRecord:
    left: str | None = None
    right: str | None = None
    left_open_probability: float | None = None
    right_open_probability: float | None = None
    both_open: bool | None = None


@dataclass(slots=True)
class ExpressionRecord:
    label: str
    confidence: float
    smile_probability: float
    scores: dict[str, float]


@dataclass(slots=True)
class FaceRecord:
    face_id: str
    bbox: tuple[int, int, int, int]
    confidence: float
    person_cluster: int | None = None
    person_id: int | None = None
    database_id: int | None = None
    embedding: list[float] | None = field(default=None, repr=False)
    eyes: EyeStateRecord | None = None
    expression: ExpressionRecord | None = None

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result.pop("embedding")
        return result


@dataclass(slots=True)
class PersonRecord:
    cluster_id: int
    face_ids: list[str]
    photo_ids: list[str]
    embedding_model: str
    centroid: list[float] = field(repr=False)
    person_id: int | None = None
    public_id: str | None = None
    name: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "person_cluster": self.cluster_id,
            "person_id": self.person_id,
            "public_id": self.public_id,
            "name": self.name,
            "faces": self.face_ids,
            "photos": self.photo_ids,
        }


@dataclass(slots=True)
class SubjectRecord:
    bbox: tuple[float, float, float, float]
    center: tuple[float, float]
    source: str


@dataclass(slots=True)
class CompositionRecord:
    rule_of_thirds: float
    frame_occupancy: float
    negative_space: float
    crop_risk: float
    score: float
    main_subject: SubjectRecord | None = None


@dataclass(slots=True)
class ColorRecord:
    balance: float
    harmony: float
    mean_saturation: float


@dataclass(slots=True)
class TagRecord:
    label: str
    confidence: float


@dataclass(slots=True)
class SemanticRecord:
    aesthetic_score: float | None
    model: str | None
    scenes: list[TagRecord] = field(default_factory=list)
    objects: list[TagRecord] = field(default_factory=list)
    embedding: list[float] | None = field(default=None, repr=False)


@dataclass(slots=True)
class StoryRecord:
    story_id: int
    title: str
    photo_ids: list[str]
    started_at: str | None
    ended_at: str | None
    representative_photo_id: str
    scene_labels: list[str] = field(default_factory=list)
    object_labels: list[str] = field(default_factory=list)
    naming_model: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class PhotoRecord:
    photo_id: str
    path: str
    width: int
    height: int
    taken_at: str | None
    sharpness: float
    exposure: float
    quality: float
    is_blurry: bool
    composition: CompositionRecord | None = None
    color: ColorRecord | None = None
    semantics: SemanticRecord | None = None
    similar_cluster: int | None = None
    story_id: int | None = None
    selected: bool = False
    faces: list[FaceRecord] = field(default_factory=list)
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["faces"] = [face.to_dict() for face in self.faces]
        if result["semantics"] is not None:
            result["semantics"].pop("embedding", None)
        return result


@dataclass(slots=True)
class PipelineConfig:
    sharpness_threshold: float = 100.0
    photo_hash_distance: int = 12
    photo_hist_similarity: float = 0.72
    photo_geometric_similarity: float | None = 0.55
    geometric_max_features: int = 4000
    geometric_neighbor_window: int = 12
    geometric_time_window_minutes: int = 15
    face_similarity: float | None = None
    min_face_size: int = 40
    min_attribute_face_size: int = 64
    max_image_side: int = 1600
    face_backend: str = "auto"
    semantic_backend: str = "auto"
    clip_model: str = "openai/clip-vit-base-patch32"
    semantic_threshold: float = 0.15
    semantic_top_k: int = 3
    semantic_batch_size: int = 8
    semantic_device: str = "auto"
    story_gap_minutes: int = 120
    story_continuity_minutes: int = 360
    story_max_duration_hours: int = 12
    story_semantic_break_minutes: int = 30
    story_naming_backend: str = "auto"
    lmstudio_url: str = "http://127.0.0.1:1234/v1"
    lmstudio_model: str = "qwen/qwen3-vl-2b"
    story_vlm_images: int = 4
    story_vlm_timeout: float = 90.0
    models_dir: Path = Path("models")
    feature_cache: bool = True
    feature_cache_dir: Path | None = None
