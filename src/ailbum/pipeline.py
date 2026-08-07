from __future__ import annotations

import csv
import json
from collections.abc import Callable
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from ailbum.cv.clustering import cluster_cosine
from ailbum.cv.faces import FaceAnalyzer
from ailbum.cv.quality import exposure_score, quality_score, sharpness_score
from ailbum.cv.similarity import PhotoFeatures, cluster_similar_photos, extract_photo_features
from ailbum.database import new_run_id, save_analysis
from ailbum.io import discover_images, load_image, relative_paths
from ailbum.metadata import ImageMetadata, collect_image_metadata
from ailbum.models import FaceRecord, PersonRecord, PhotoRecord, PipelineConfig

Progress = Callable[[str], None]


def analyze_library(
    source: Path,
    output: Path,
    config: PipelineConfig,
    recursive: bool = True,
    progress: Progress | None = None,
    database: Path | None = None,
) -> dict[str, object]:
    started_at = datetime.now(timezone.utc).isoformat()
    emit = progress or (lambda _: None)
    paths = discover_images(source, recursive=recursive)
    if not paths:
        raise ValueError(f"No supported images found in {source}")
    display_paths = relative_paths(paths, source)
    output.mkdir(parents=True, exist_ok=True)

    face_analyzer = FaceAnalyzer(
        config.models_dir, backend=config.face_backend, min_face_size=config.min_face_size
    )
    face_similarity = config.face_similarity
    if face_similarity is None:
        face_similarity = 0.36 if face_analyzer.backend == "dnn" else 0.82
    records: list[PhotoRecord] = []
    photo_features: list[PhotoFeatures | None] = []
    face_features: list[tuple[int, int, np.ndarray]] = []
    image_metadata: list[ImageMetadata] = []

    for index, path in enumerate(paths, start=1):
        emit(f"[{index}/{len(paths)}] {display_paths[path]}")
        metadata = collect_image_metadata(path, source)
        image_metadata.append(metadata)
        try:
            image = load_image(path)
            height, width = image.shape[:2]
            sharpness = sharpness_score(image, config.max_image_side)
            exposure = exposure_score(image)
            record = PhotoRecord(
                photo_id=f"photo-{index:05d}",
                path=str(path.resolve()),
                width=width,
                height=height,
                taken_at=metadata.taken_at or metadata.modified_at,
                sharpness=round(sharpness, 3),
                exposure=round(exposure, 4),
                quality=round(quality_score(sharpness, exposure), 4),
                is_blurry=sharpness < config.sharpness_threshold,
            )
            photo_features.append(extract_photo_features(image))
            for face_index, (detection, embedding) in enumerate(face_analyzer.analyze(image), start=1):
                record.faces.append(
                    FaceRecord(
                        face_id=f"{record.photo_id}-face-{face_index:02d}",
                        bbox=detection.bbox,
                        confidence=round(detection.confidence, 4),
                        embedding=np.asarray(embedding, dtype=np.float32).reshape(-1).tolist(),
                    )
                )
                face_features.append(
                    (len(records), face_index - 1, np.asarray(embedding, dtype=np.float32))
                )
            records.append(record)
        # Continue a large import while making a corrupt file or backend failure visible.
        except Exception as error:  # noqa: BLE001
            records.append(
                PhotoRecord(
                    photo_id=f"photo-{index:05d}",
                    path=str(path.resolve()),
                    width=0,
                    height=0,
                    taken_at=None,
                    sharpness=0.0,
                    exposure=0.0,
                    quality=0.0,
                    is_blurry=True,
                    error=f"{type(error).__name__}: {error}",
                )
            )
            photo_features.append(None)

    valid_indices = [index for index, feature in enumerate(photo_features) if feature is not None]
    groups = cluster_similar_photos(
        [photo_features[index] for index in valid_indices],  # type: ignore[misc]
        config.photo_hash_distance,
        config.photo_hist_similarity,
    )
    similar_groups: list[dict[str, object]] = []
    for cluster_id, local_group in enumerate(groups, start=1):
        member_indices = [valid_indices[index] for index in local_group]
        if len(member_indices) > 1:
            for index in member_indices:
                records[index].similar_cluster = cluster_id
        candidates = [index for index in member_indices if not records[index].is_blurry]
        if candidates:
            best = max(candidates, key=lambda item: records[item].quality)
            records[best].selected = True
        if len(member_indices) > 1:
            similar_groups.append(
                {
                    "cluster_id": cluster_id,
                    "members": [records[index].photo_id for index in member_indices],
                    "selected": records[best].photo_id if candidates else None,
                }
            )

    people: list[PersonRecord] = []
    embeddings = [item[2] for item in face_features]
    for person_id, member_indices in enumerate(
        cluster_cosine(embeddings, face_similarity), start=1
    ):
        face_ids: list[str] = []
        photo_ids: set[str] = set()
        for feature_index in member_indices:
            photo_index, face_index, _ = face_features[feature_index]
            face = records[photo_index].faces[face_index]
            face.person_cluster = person_id
            face_ids.append(face.face_id)
            photo_ids.add(records[photo_index].photo_id)
        centroid = np.mean([embeddings[index] for index in member_indices], axis=0)
        norm = float(np.linalg.norm(centroid))
        if norm > 0:
            centroid = centroid / norm
        people.append(
            PersonRecord(
                cluster_id=person_id,
                face_ids=face_ids,
                photo_ids=sorted(photo_ids),
                embedding_model=(
                    "sface-2021dec" if face_analyzer.backend == "dnn" else "classic-hog-color-v1"
                ),
                centroid=np.asarray(centroid, dtype=np.float32).reshape(-1).tolist(),
            )
        )

    manifest: dict[str, object] = {
        "schema_version": 2,
        "run_id": new_run_id(),
        "started_at": started_at,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": str(source.resolve()),
        "database": str(database.resolve()) if database else None,
        "face_backend": face_analyzer.backend,
        "config": {
            **asdict(config),
            "face_similarity": face_similarity,
            "models_dir": str(config.models_dir),
        },
        "summary": {
            "photos": len(records),
            "errors": sum(record.error is not None for record in records),
            "blurry": sum(record.is_blurry for record in records),
            "selected": sum(record.selected for record in records),
            "similar_groups": len(similar_groups),
            "faces": sum(len(record.faces) for record in records),
            "people_groups": len(people),
        },
        "similar_groups": similar_groups,
        "people_groups": [person.to_dict() for person in people],
        "photos": [record.to_dict() for record in records],
    }
    if database is not None:
        save_analysis(
            database,
            source,
            output,
            manifest,
            records,
            people,
            image_metadata,
            face_similarity,
        )
        manifest["people_groups"] = [person.to_dict() for person in people]
        manifest["photos"] = [record.to_dict() for record in records]
    _write_outputs(output, manifest, records)
    return manifest


def _write_outputs(output: Path, manifest: dict[str, object], records: list[PhotoRecord]) -> None:
    (output / "analysis.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    with (output / "selection.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(
            [
                "photo_id",
                "path",
                "sharpness",
                "exposure",
                "quality",
                "blurry",
                "similar_cluster",
                "faces",
                "selected",
                "error",
            ]
        )
        for record in records:
            writer.writerow(
                [
                    record.photo_id,
                    record.path,
                    record.sharpness,
                    record.exposure,
                    record.quality,
                    record.is_blurry,
                    record.similar_cluster or "",
                    len(record.faces),
                    record.selected,
                    record.error or "",
                ]
            )
