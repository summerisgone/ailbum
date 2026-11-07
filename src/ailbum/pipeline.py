from __future__ import annotations

import csv
import json
from collections.abc import Callable
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from ailbum.cv.aesthetics import analyze_color, analyze_composition
from ailbum.cv.clustering import cluster_cosine
from ailbum.cv.faces import FaceAnalyzer
from ailbum.cv.quality import AnalysisImagePyramid, exposure_score, quality_score, sharpness_score
from ailbum.cv.semantics import SemanticAnalyzer
from ailbum.cv.similarity import PhotoFeatures, cluster_similar_photos, extract_photo_features
from ailbum.database import new_run_id, save_analysis
from ailbum.feature_cache import FeatureCache, cache_signature
from ailbum.io import discover_images, load_image, relative_paths
from ailbum.metadata import ImageMetadata, collect_image_metadata
from ailbum.models import (
    ExpressionRecord,
    EyeStateRecord,
    FaceRecord,
    PersonRecord,
    PhotoRecord,
    PipelineConfig,
)
from ailbum.stories import StoryPhoto, detect_stories
from ailbum.story_naming import StoryNamer

Progress = Callable[[str], None]


def _feature_cache(
    config: PipelineConfig,
    output: Path,
    database: Path | None,
    face_analyzer: FaceAnalyzer,
    semantic_analyzer: SemanticAnalyzer,
) -> FeatureCache | None:
    if not config.feature_cache:
        return None
    root = config.feature_cache_dir
    if root is None:
        root = database.parent / "feature-cache" if database else output / ".feature-cache"
    model_files = []
    if config.models_dir.exists():
        model_files = [
            (path.name, path.stat().st_size, path.stat().st_mtime_ns)
            for path in sorted(config.models_dir.glob("*.onnx"))
        ]
    signature = cache_signature(
        {
            "max_image_side": config.max_image_side,
            "geometric_enabled": config.photo_geometric_similarity is not None,
            "geometric_max_features": config.geometric_max_features,
            "face_backend": face_analyzer.backend,
            "face_models": model_files,
            "min_face_size": config.min_face_size,
            "min_attribute_face_size": config.min_attribute_face_size,
            "semantic_backend": semantic_analyzer.backend,
            "semantic_model": semantic_analyzer.model_name,
            "semantic_threshold": config.semantic_threshold,
            "semantic_top_k": config.semantic_top_k,
        }
    )
    return FeatureCache(root, signature)


def _append_face_features(
    record_index: int,
    record: PhotoRecord,
    face_features: list[tuple[int, int, np.ndarray]],
) -> None:
    for face_index, face in enumerate(record.faces):
        if face.embedding is not None:
            face_features.append(
                (record_index, face_index, np.asarray(face.embedding, dtype=np.float32))
            )


def _active_pairwise_model(database: Path | None):
    if database is None:
        return None
    try:
        from ailbum.database import connect
        from ailbum.ranking import store

        with connect(database) as connection:
            return store.active_model(connection, "pairwise")
    except (ImportError, AttributeError):
        return None


def _group_winner(
    records: list[PhotoRecord], members: list[int], candidates: list[int], model
) -> int:
    if model is None:
        return max(candidates, key=lambda item: records[item].quality)
    from ailbum.ranking import features

    order = sorted(members, key=lambda item: (-records[item].quality, item))
    vectors = np.array(
        [features.from_record(records[i], len(members), order.index(i)) for i in candidates]
    )
    scores = model.score(vectors)
    best = max(range(len(candidates)), key=lambda k: (scores[k], records[candidates[k]].quality))
    return candidates[best]


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
    emit(f"Этап: Подготовка анализа|Найдено фотографий: {len(paths)}")
    display_paths = relative_paths(paths, source)
    output.mkdir(parents=True, exist_ok=True)
    if config.semantic_batch_size < 1:
        raise ValueError("Semantic batch size must be positive")
    if config.geometric_neighbor_window < 1:
        raise ValueError("Geometric neighbor window must be positive")
    if config.geometric_time_window_minutes < 1:
        raise ValueError("Geometric time window must be positive")

    emit("Этап: Загрузка моделей|Подготавливаем анализ качества, лиц и содержимого")
    face_analyzer = FaceAnalyzer(
        config.models_dir,
        backend=config.face_backend,
        min_face_size=config.min_face_size,
        min_attribute_face_size=config.min_attribute_face_size,
    )
    semantic_analyzer = SemanticAnalyzer(
        config.semantic_backend,
        config.clip_model,
        config.semantic_threshold,
        config.semantic_top_k,
        device=config.semantic_device,
    )
    feature_cache = _feature_cache(config, output, database, face_analyzer, semantic_analyzer)
    face_similarity = config.face_similarity
    if face_similarity is None:
        face_similarity = 0.36 if face_analyzer.backend == "dnn" else 0.82
    records: list[PhotoRecord] = []
    photo_features: list[PhotoFeatures | None] = []
    face_features: list[tuple[int, int, np.ndarray]] = []
    image_metadata: list[ImageMetadata] = []
    pending_semantics: list[tuple[int, np.ndarray, str, PhotoFeatures]] = []

    def flush_semantics() -> None:
        if not pending_semantics:
            return
        try:
            semantic_records = semantic_analyzer.analyze_many(
                [item[1] for item in pending_semantics]
            )
        except Exception as error:  # noqa: BLE001 - semantic inference is non-critical
            semantic_analyzer.error = f"{type(error).__name__}: {error}"
            pending_semantics.clear()
            return
        for (record_index, _, sha256, features), semantics in zip(
            pending_semantics, semantic_records, strict=True
        ):
            records[record_index].semantics = semantics
            if feature_cache is not None:
                feature_cache.store(sha256, records[record_index], features)
        pending_semantics.clear()

    emit("Этап: Анализ фотографий|Метаданные, качество, лица и содержимое")
    for index, path in enumerate(paths, start=1):
        emit(f"[{index}/{len(paths)}] {display_paths[path]}")
        metadata = collect_image_metadata(path, source)
        image_metadata.append(metadata)
        photo_id = f"photo-{index:05d}"
        taken_at = metadata.taken_at or metadata.modified_at
        if feature_cache is not None:
            cached = feature_cache.load(
                metadata.sha256,
                photo_id=photo_id,
                path=path,
                taken_at=taken_at,
                sharpness_threshold=config.sharpness_threshold,
            )
            if cached is not None:
                record, features = cached
                record_index = len(records)
                records.append(record)
                photo_features.append(features)
                _append_face_features(record_index, record, face_features)
                continue
        try:
            image = load_image(path)
            height, width = image.shape[:2]
            pyramid = AnalysisImagePyramid(image)
            analysis_image = pyramid.get(config.max_image_side)
            preview = pyramid.get(800)
            similarity_preview = pyramid.get(256)
            sharpness = sharpness_score(analysis_image, config.max_image_side)
            exposure = exposure_score(preview)
            record = PhotoRecord(
                photo_id=photo_id,
                path=str(path.resolve()),
                width=width,
                height=height,
                taken_at=taken_at,
                sharpness=round(sharpness, 3),
                exposure=round(exposure, 4),
                quality=round(quality_score(sharpness, exposure), 4),
                is_blurry=sharpness < config.sharpness_threshold,
            )
            features = extract_photo_features(
                image,
                geometric_max_features=config.geometric_max_features,
                geometric_max_image_side=config.max_image_side,
                include_geometric=config.photo_geometric_similarity is not None,
                hash_color_image=similarity_preview,
                geometric_image=analysis_image,
            )
            photo_features.append(features)
            for face_index, analysis in enumerate(face_analyzer.analyze(image), start=1):
                detection = analysis.detection
                embedding = analysis.embedding
                attributes = analysis.attributes
                eyes = None
                if attributes.left_eye is not None or attributes.right_eye is not None:
                    eyes = EyeStateRecord(
                        left=attributes.left_eye,
                        right=attributes.right_eye,
                        left_open_probability=attributes.left_eye_open_probability,
                        right_open_probability=attributes.right_eye_open_probability,
                        both_open=attributes.both_eyes_open,
                    )
                expression = None
                if (
                    attributes.expression is not None
                    and attributes.expression_confidence is not None
                    and attributes.expression_scores is not None
                    and attributes.smile_probability is not None
                ):
                    expression = ExpressionRecord(
                        label=attributes.expression,
                        confidence=attributes.expression_confidence,
                        smile_probability=attributes.smile_probability,
                        scores=attributes.expression_scores,
                    )
                record.faces.append(
                    FaceRecord(
                        face_id=f"{record.photo_id}-face-{face_index:02d}",
                        bbox=detection.bbox,
                        confidence=round(detection.confidence, 4),
                        embedding=np.asarray(embedding, dtype=np.float32).reshape(-1).tolist(),
                        eyes=eyes,
                        expression=expression,
                    )
                )
            record.composition = analyze_composition(
                image,
                [face.bbox for face in record.faces],
                analysis_image=preview,
            )
            record.color = analyze_color(preview)
            record_index = len(records)
            records.append(record)
            _append_face_features(record_index, record, face_features)
            pending_semantics.append((record_index, preview, metadata.sha256, features))
            if len(pending_semantics) >= config.semantic_batch_size:
                flush_semantics()
        # Continue a large import while making a corrupt file or backend failure visible.
        except Exception as error:  # noqa: BLE001
            records.append(
                PhotoRecord(
                    photo_id=photo_id,
                    path=str(path.resolve()),
                    width=0,
                    height=0,
                    taken_at=taken_at,
                    sharpness=0.0,
                    exposure=0.0,
                    quality=0.0,
                    is_blurry=True,
                    error=f"{type(error).__name__}: {error}",
                )
            )
            photo_features.append(None)

    flush_semantics()

    emit("Этап: Поиск похожих кадров|Группируем дубли и серии")
    valid_indices = [index for index, feature in enumerate(photo_features) if feature is not None]
    groups = cluster_similar_photos(
        [photo_features[index] for index in valid_indices],  # type: ignore[misc]
        config.photo_hash_distance,
        config.photo_hist_similarity,
        config.photo_geometric_similarity,
        capture_times=[records[index].taken_at for index in valid_indices],
        geometric_neighbor_window=config.geometric_neighbor_window,
        geometric_time_window_minutes=config.geometric_time_window_minutes,
    )
    similar_groups: list[dict[str, object]] = []
    pairwise_model = _active_pairwise_model(database)
    selection_model = (
        f"pairwise:{getattr(pairwise_model, 'id', None)}" if pairwise_model is not None else "quality"
    )
    for cluster_id, local_group in enumerate(groups, start=1):
        member_indices = [valid_indices[index] for index in local_group]
        if len(member_indices) > 1:
            for index in member_indices:
                records[index].similar_cluster = cluster_id
        candidates = [index for index in member_indices if not records[index].is_blurry]
        if candidates:
            best = _group_winner(records, member_indices, candidates, pairwise_model)
            records[best].selected = True
        if len(member_indices) > 1:
            similar_groups.append(
                {
                    "cluster_id": cluster_id,
                    "members": [records[index].photo_id for index in member_indices],
                    "selected": records[best].photo_id if candidates else None,
                }
            )

    emit("Этап: Группировка лиц|Связываем похожие лица с людьми")
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

    emit("Этап: Формирование сюжетов|Объединяем фотографии по времени и содержимому")
    stories = detect_stories(
        [
            StoryPhoto(
                photo_id=record.photo_id,
                taken_at=record.taken_at,
                gps_latitude=metadata.gps_latitude,
                gps_longitude=metadata.gps_longitude,
                people=frozenset(
                    f"cluster:{face.person_cluster}"
                    for face in record.faces
                    if face.person_cluster is not None
                ),
                scenes=tuple(
                    (tag.label, tag.confidence)
                    for tag in (record.semantics.scenes if record.semantics else [])
                ),
                objects=tuple(
                    (tag.label, tag.confidence)
                    for tag in (record.semantics.objects if record.semantics else [])
                ),
                embedding=(
                    tuple(record.semantics.embedding)
                    if record.semantics and record.semantics.embedding
                    else None
                ),
                quality=record.quality,
                is_blurry=record.is_blurry,
            )
            for record, metadata in zip(records, image_metadata, strict=True)
        ],
        gap_minutes=config.story_gap_minutes,
        continuity_minutes=config.story_continuity_minutes,
        max_duration_hours=config.story_max_duration_hours,
        semantic_break_minutes=config.story_semantic_break_minutes,
    )
    emit("Этап: Названия сюжетов|Подбираем названия для групп фотографий")
    story_namer = StoryNamer(
        backend=config.story_naming_backend,
        base_url=config.lmstudio_url,
        model=config.lmstudio_model,
        max_images=config.story_vlm_images,
        timeout=config.story_vlm_timeout,
    )
    stories = story_namer.refine(
        stories,
        {record.photo_id: record.path for record in records},
    )
    story_by_photo = {
        photo_id: story.story_id for story in stories for photo_id in story.photo_ids
    }
    for record in records:
        record.story_id = story_by_photo[record.photo_id]

    config_payload = asdict(config)
    config_payload["models_dir"] = str(config.models_dir)
    config_payload["feature_cache_dir"] = (
        str(config.feature_cache_dir) if config.feature_cache_dir is not None else None
    )
    cache_stats = (
        feature_cache.stats()
        if feature_cache is not None
        else {"enabled": False, "hits": 0, "misses": 0, "writes": 0, "error": None}
    )
    manifest: dict[str, object] = {
        "schema_version": 6,
        "run_id": new_run_id(),
        "started_at": started_at,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": str(source.resolve()),
        "database": str(database.resolve()) if database else None,
        "face_backend": face_analyzer.backend,
        "face_attribute_models": face_analyzer.attribute_models,
        "semantic_backend": semantic_analyzer.backend,
        "semantic_model": semantic_analyzer.model_name if semantic_analyzer.available else None,
        "semantic_error": semantic_analyzer.error,
        "semantic_device": semantic_analyzer.device,
        "feature_cache": cache_stats,
        "selection_model": selection_model,
        "story_naming_backend": story_namer.backend,
        "story_naming_model": (
            story_namer.model if story_namer.backend == "lmstudio" else None
        ),
        "story_naming_error": story_namer.error,
        "config": {
            **config_payload,
            "face_similarity": face_similarity,
        },
        "summary": {
            "photos": len(records),
            "errors": sum(record.error is not None for record in records),
            "blurry": sum(record.is_blurry for record in records),
            "selected": sum(record.selected for record in records),
            "similar_groups": len(similar_groups),
            "faces": sum(len(record.faces) for record in records),
            "faces_with_eye_state": sum(
                face.eyes is not None for record in records for face in record.faces
            ),
            "faces_with_expression": sum(
                face.expression is not None for record in records for face in record.faces
            ),
            "people_groups": len(people),
            "stories": len(stories),
            "photos_with_aesthetic_score": sum(
                record.semantics is not None
                and record.semantics.aesthetic_score is not None
                for record in records
            ),
            "photos_with_scene_tags": sum(
                record.semantics is not None and bool(record.semantics.scenes)
                for record in records
            ),
            "feature_cache_hits": cache_stats["hits"],
        },
        "similar_groups": similar_groups,
        "people_groups": [person.to_dict() for person in people],
        "story_groups": [story.to_dict() for story in stories],
        "photos": [record.to_dict() for record in records],
    }
    if database is not None:
        emit("Этап: Сохранение|Записываем результаты анализа в базу данных")
        save_analysis(
            database,
            source,
            output,
            manifest,
            records,
            people,
            image_metadata,
            face_similarity,
            stories=stories,
        )
        manifest["people_groups"] = [person.to_dict() for person in people]
        manifest["photos"] = [record.to_dict() for record in records]
    emit("Этап: Завершение|Формируем файлы результатов")
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
                "aesthetic_score",
                "composition_score",
                "rule_of_thirds",
                "frame_occupancy",
                "negative_space",
                "crop_risk",
                "color_balance",
                "color_harmony",
                "scene_tags",
                "object_tags",
                "blurry",
                "similar_cluster",
                "story_id",
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
                    (
                        record.semantics.aesthetic_score
                        if record.semantics is not None
                        else ""
                    ),
                    record.composition.score if record.composition is not None else "",
                    (
                        record.composition.rule_of_thirds
                        if record.composition is not None
                        else ""
                    ),
                    (
                        record.composition.frame_occupancy
                        if record.composition is not None
                        else ""
                    ),
                    (
                        record.composition.negative_space
                        if record.composition is not None
                        else ""
                    ),
                    record.composition.crop_risk if record.composition is not None else "",
                    record.color.balance if record.color is not None else "",
                    record.color.harmony if record.color is not None else "",
                    (
                        ";".join(tag.label for tag in record.semantics.scenes)
                        if record.semantics is not None
                        else ""
                    ),
                    (
                        ";".join(tag.label for tag in record.semantics.objects)
                        if record.semantics is not None
                        else ""
                    ),
                    record.is_blurry,
                    record.similar_cluster or "",
                    record.story_id or "",
                    len(record.faces),
                    record.selected,
                    record.error or "",
                ]
            )
