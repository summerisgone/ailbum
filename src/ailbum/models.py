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
    similar_cluster: int | None = None
    selected: bool = False
    faces: list[FaceRecord] = field(default_factory=list)
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["faces"] = [face.to_dict() for face in self.faces]
        return result


@dataclass(slots=True)
class PipelineConfig:
    sharpness_threshold: float = 100.0
    photo_hash_distance: int = 12
    photo_hist_similarity: float = 0.72
    photo_geometric_similarity: float | None = 0.55
    geometric_max_features: int = 4000
    face_similarity: float | None = None
    min_face_size: int = 40
    min_attribute_face_size: int = 64
    max_image_side: int = 1600
    face_backend: str = "auto"
    models_dir: Path = Path("models")
