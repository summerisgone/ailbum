from __future__ import annotations

import hashlib
import json
from dataclasses import asdict
from pathlib import Path
from typing import Any

import numpy as np

from ailbum.cv.similarity import GeometricFeatures, PhotoFeatures
from ailbum.models import (
    ColorRecord,
    CompositionRecord,
    ExpressionRecord,
    EyeStateRecord,
    FaceRecord,
    PhotoRecord,
    SemanticRecord,
    SubjectRecord,
    TagRecord,
)

CACHE_SCHEMA_VERSION = 1


def cache_signature(settings: dict[str, Any]) -> str:
    payload = json.dumps(
        {"schema": CACHE_SCHEMA_VERSION, **settings},
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:20]


class FeatureCache:
    """Versioned, non-critical cache of complete per-photo CV results."""

    def __init__(self, root: Path, signature: str) -> None:
        self.directory = root / signature
        self.hits = 0
        self.misses = 0
        self.writes = 0
        self.error: str | None = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            self.error = f"{type(error).__name__}: {error}"

    @property
    def available(self) -> bool:
        return self.error is None

    def load(
        self,
        sha256: str,
        *,
        photo_id: str,
        path: Path,
        taken_at: str | None,
        sharpness_threshold: float,
    ) -> tuple[PhotoRecord, PhotoFeatures] | None:
        if not self.available:
            return None
        cache_path = self.directory / f"{sha256}.npz"
        try:
            with np.load(cache_path, allow_pickle=False) as archive:
                metadata = json.loads(str(archive["metadata"].item()))
                features = _load_features(archive, metadata)
            record = _load_record(
                metadata,
                photo_id=photo_id,
                path=path,
                taken_at=taken_at,
                sharpness_threshold=sharpness_threshold,
            )
        except FileNotFoundError:
            self.misses += 1
            return None
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.misses += 1
            return None
        self.hits += 1
        return record, features

    def store(self, sha256: str, record: PhotoRecord, features: PhotoFeatures) -> None:
        if not self.available:
            return
        cache_path = self.directory / f"{sha256}.npz"
        temporary = cache_path.with_suffix(".tmp")
        metadata = _record_metadata(record, features)
        geometric = features.geometric
        arrays: dict[str, np.ndarray] = {
            "metadata": np.asarray(json.dumps(metadata, ensure_ascii=False, separators=(",", ":"))),
            "phash": np.asarray(features.phash, dtype=np.bool_),
            "histogram": np.asarray(features.color_histogram, dtype=np.float32),
            "keypoints": (
                np.asarray(geometric.keypoints, dtype=np.float32)
                if geometric is not None
                else np.empty((0, 2), dtype=np.float32)
            ),
            "descriptors": (
                np.asarray(geometric.descriptors, dtype=np.float32)
                if geometric is not None and geometric.descriptors is not None
                else np.empty((0, 0), dtype=np.float32)
            ),
        }
        try:
            with temporary.open("wb") as stream:
                np.savez(stream, **arrays)
            temporary.replace(cache_path)
            self.writes += 1
        except OSError as error:
            self.error = f"{type(error).__name__}: {error}"

    def stats(self) -> dict[str, object]:
        return {
            "enabled": self.available,
            "directory": str(self.directory),
            "hits": self.hits,
            "misses": self.misses,
            "writes": self.writes,
            "error": self.error,
        }


def _record_metadata(record: PhotoRecord, features: PhotoFeatures) -> dict[str, Any]:
    geometric = features.geometric
    return {
        "width": record.width,
        "height": record.height,
        "sharpness": record.sharpness,
        "exposure": record.exposure,
        "quality": record.quality,
        "composition": asdict(record.composition) if record.composition else None,
        "color": asdict(record.color) if record.color else None,
        "semantics": asdict(record.semantics) if record.semantics else None,
        "faces": [asdict(face) for face in record.faces],
        "geometric": (
            {
                "width": geometric.width,
                "height": geometric.height,
                "has_descriptors": geometric.descriptors is not None,
            }
            if geometric is not None
            else None
        ),
    }


def _load_record(
    metadata: dict[str, Any],
    *,
    photo_id: str,
    path: Path,
    taken_at: str | None,
    sharpness_threshold: float,
) -> PhotoRecord:
    sharpness = float(metadata["sharpness"])
    faces = [_load_face(item, photo_id, index) for index, item in enumerate(metadata["faces"], 1)]
    return PhotoRecord(
        photo_id=photo_id,
        path=str(path.resolve()),
        width=int(metadata["width"]),
        height=int(metadata["height"]),
        taken_at=taken_at,
        sharpness=sharpness,
        exposure=float(metadata["exposure"]),
        quality=float(metadata["quality"]),
        is_blurry=sharpness < sharpness_threshold,
        composition=_load_composition(metadata.get("composition")),
        color=ColorRecord(**metadata["color"]) if metadata.get("color") else None,
        semantics=_load_semantics(metadata.get("semantics")),
        faces=faces,
    )


def _load_face(data: dict[str, Any], photo_id: str, index: int) -> FaceRecord:
    eyes = EyeStateRecord(**data["eyes"]) if data.get("eyes") else None
    expression = ExpressionRecord(**data["expression"]) if data.get("expression") else None
    return FaceRecord(
        face_id=f"{photo_id}-face-{index:02d}",
        bbox=tuple(int(value) for value in data["bbox"]),
        confidence=float(data["confidence"]),
        embedding=[float(value) for value in data["embedding"]],
        eyes=eyes,
        expression=expression,
    )


def _load_composition(data: dict[str, Any] | None) -> CompositionRecord | None:
    if data is None:
        return None
    subject_data = data.get("main_subject")
    subject = (
        SubjectRecord(
            bbox=tuple(float(value) for value in subject_data["bbox"]),
            center=tuple(float(value) for value in subject_data["center"]),
            source=str(subject_data["source"]),
        )
        if subject_data
        else None
    )
    return CompositionRecord(
        rule_of_thirds=float(data["rule_of_thirds"]),
        frame_occupancy=float(data["frame_occupancy"]),
        negative_space=float(data["negative_space"]),
        crop_risk=float(data["crop_risk"]),
        score=float(data["score"]),
        main_subject=subject,
    )


def _load_semantics(data: dict[str, Any] | None) -> SemanticRecord | None:
    if data is None:
        return None
    return SemanticRecord(
        aesthetic_score=data.get("aesthetic_score"),
        model=data.get("model"),
        scenes=[TagRecord(**item) for item in data.get("scenes", [])],
        objects=[TagRecord(**item) for item in data.get("objects", [])],
        embedding=(
            [float(value) for value in data["embedding"]]
            if data.get("embedding") is not None
            else None
        ),
    )


def _load_features(archive: Any, metadata: dict[str, Any]) -> PhotoFeatures:
    geometric_data = metadata.get("geometric")
    geometric = None
    if geometric_data is not None:
        descriptors = (
            np.asarray(archive["descriptors"], dtype=np.float32).copy()
            if geometric_data["has_descriptors"]
            else None
        )
        geometric = GeometricFeatures(
            keypoints=np.asarray(archive["keypoints"], dtype=np.float32).copy(),
            descriptors=descriptors,
            width=int(geometric_data["width"]),
            height=int(geometric_data["height"]),
        )
    return PhotoFeatures(
        phash=np.asarray(archive["phash"], dtype=np.bool_).copy(),
        color_histogram=np.asarray(archive["histogram"], dtype=np.float32).copy(),
        geometric=geometric,
    )
