from __future__ import annotations

import json
import sqlite3
from collections import defaultdict
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import cv2

from ailbum import proxies
from ailbum.cv.objects import DETECTOR_MODEL, DetectedObject, ObjectDetector
from ailbum.io import load_image
from ailbum.layout.store import album_run
from ailbum.layout.types import Rect, Region

FACE_BACKGROUND_RATIO = 0.05
OBJECT_CONFIDENCE = 0.5
SELECTED_BONUS = 0.2


@dataclass(frozen=True, slots=True)
class PhotoFacts:
    image_id: int
    aspect: float
    unit_key: str
    story_id: int | None
    taken_at: str | None
    rank: float
    selected: bool
    regions: tuple[Region, ...]


def _clip_rect(x0: float, y0: float, x1: float, y1: float) -> Rect | None:
    x0, y0 = max(0.0, x0), max(0.0, y0)
    x1, y1 = min(1.0, x1), min(1.0, y1)
    if x1 - x0 <= 0.0 or y1 - y0 <= 0.0:
        return None
    return Rect(x0, y0, x1 - x0, y1 - y0)


def build_regions(
    faces: Sequence[tuple[float, float, float, float]],
    objects: Sequence[DetectedObject],
    subject: Rect | None,
) -> tuple[Region, ...]:
    """Protected regions in image fractions; faces are (x, y, w, h) fractions."""
    regions: list[Region] = []
    largest = max((w * h for _, _, w, h in faces), default=0.0)
    for x, y, w, h in faces:
        if w * h <= 0.0:
            continue
        if w * h >= FACE_BACKGROUND_RATIO * largest:
            rect = _clip_rect(x - 0.2 * w, y - 0.35 * h, x + 1.2 * w, y + 1.15 * h)
            if rect:
                regions.append(Region(rect, 1.0, True, "face"))
        else:
            rect = _clip_rect(x, y, x + w, y + h)
            if rect:
                regions.append(Region(rect, 0.2, False, "face_background"))
    for item in objects:
        is_person = item.label == "person"
        if not is_person and item.score < OBJECT_CONFIDENCE:
            continue
        x, y, w, h = item.bbox
        rect = _clip_rect(x, y, x + w, y + h)
        if rect:
            regions.append(
                Region(rect, 0.6 if is_person else 0.5, False, "person" if is_person else "object")
            )
    if not regions and subject is not None:
        rect = _clip_rect(subject.x, subject.y, subject.x + subject.w, subject.y + subject.h)
        if rect:
            regions.append(Region(rect, 0.3, False, "subject"))
    return tuple(regions)


def load_pool(
    connection: sqlite3.Connection,
    album_id: int,
    detector: ObjectDetector | None,
    progress: Callable[[int, int], None] | None = None,
) -> list[PhotoFacts]:
    run_id = album_run(connection, album_id)
    database = Path(connection.execute("PRAGMA database_list").fetchone()[2])
    rows = connection.execute(
        """
        SELECT pa.image_id, pa.quality, pa.aesthetic_score, pa.main_subject_json,
               pa.similar_cluster, pa.story_id, ps.image_id IS NOT NULL AS selected,
               i.path, i.sha256, i.availability, i.width, i.height, i.orientation, i.taken_at
        FROM photo_analysis AS pa
        JOIN images AS i ON i.id = pa.image_id
        LEFT JOIN album_photos AS ps ON ps.album_id = ? AND ps.image_id = pa.image_id
        WHERE pa.run_id = ? AND pa.error IS NULL
          AND (ps.image_id IS NOT NULL
               OR (pa.is_blurry = 0 AND pa.similar_cluster IS NOT NULL
                   AND pa.similar_cluster IN (
                       SELECT pa2.similar_cluster FROM photo_analysis AS pa2
                       JOIN album_photos AS ps2
                         ON ps2.album_id = ? AND ps2.image_id = pa2.image_id
                       WHERE pa2.run_id = pa.run_id AND pa2.similar_cluster IS NOT NULL)))
        ORDER BY pa.image_id
        """,
        (album_id, run_id, album_id),
    ).fetchall()
    rows = [
        row
        for row in rows
        if row["width"] and row["height"] and proxies.image_source(database, dict(row)) is not None
    ]

    faces: dict[int, list[sqlite3.Row]] = defaultdict(list)
    for face in connection.execute(
        """SELECT image_id, bbox_x, bbox_y, bbox_width, bbox_height, both_eyes_open,
                  smile_probability
           FROM faces WHERE run_id = ? ORDER BY image_id, face_index""",
        (run_id,),
    ):
        faces[face["image_id"]].append(face)

    facts: list[PhotoFacts] = []
    total = len(rows)
    for done, row in enumerate(rows, 1):
        width, height = row["width"], row["height"]
        if row["orientation"] in (5, 6, 7, 8):
            width, height = height, width
        image_faces = faces.get(row["image_id"], [])
        face_boxes = [
            (
                face["bbox_x"] / width,
                face["bbox_y"] / height,
                face["bbox_width"] / width,
                face["bbox_height"] / height,
            )
            for face in image_faces
        ]
        objects = _objects_for(connection, row, detector)
        regions = build_regions(face_boxes, objects, _subject(row["main_subject_json"]))
        facts.append(
            PhotoFacts(
                image_id=row["image_id"],
                aspect=width / height,
                unit_key=(
                    f"cluster:{row['similar_cluster']}"
                    if row["similar_cluster"] is not None
                    else f"image:{row['image_id']}"
                ),
                story_id=row["story_id"],
                taken_at=row["taken_at"],
                rank=_rank(row, image_faces),
                selected=bool(row["selected"]),
                regions=regions,
            )
        )
        if progress:
            progress(done, total)
    return facts


def _subject(raw: str | None) -> Rect | None:
    if not raw:
        return None
    try:
        x, y, w, h = json.loads(raw)["bbox"]
        return Rect(float(x), float(y), float(w), float(h))
    except (ValueError, KeyError, TypeError):
        return None


def _rank(row: sqlite3.Row, faces: Sequence[sqlite3.Row]) -> float:
    quality = row["quality"] or 0.0
    aesthetic = row["aesthetic_score"] if row["aesthetic_score"] is not None else quality
    rank = 0.45 * quality + 0.35 * aesthetic
    if faces:
        smiling = sum(1 for face in faces if (face["smile_probability"] or 0.0) >= 0.5)
        rank += 0.1 * min(1.0, smiling / len(faces))
        if any(face["both_eyes_open"] == 0 for face in faces):
            rank -= 0.2
    if row["selected"]:
        rank += SELECTED_BONUS
    return min(1.0, max(0.0, rank))


def _objects_for(
    connection: sqlite3.Connection, row: sqlite3.Row, detector: ObjectDetector | None
) -> list[DetectedObject]:
    cached = connection.execute(
        "SELECT sha256, objects_json FROM image_object_scans "
        "WHERE image_id = ? AND detector_model = ?",
        (row["image_id"], DETECTOR_MODEL),
    ).fetchone()
    if cached is not None and cached["sha256"] == row["sha256"]:
        return [
            DetectedObject(item["label"], item["score"], tuple(item["bbox"]))
            for item in json.loads(cached["objects_json"])
        ]
    if detector is None or row["availability"] != "present":
        return []
    try:
        image = cv2.cvtColor(load_image(Path(row["path"])), cv2.COLOR_BGR2RGB)
        objects = detector.detect(image)
    except (OSError, ValueError, cv2.error):
        return []
    connection.execute(
        """INSERT OR REPLACE INTO image_object_scans
           (image_id, detector_model, sha256, objects_json, scanned_at) VALUES (?, ?, ?, ?, ?)""",
        (
            row["image_id"],
            DETECTOR_MODEL,
            row["sha256"],
            json.dumps(
                [
                    {"label": o.label, "score": o.score, "bbox": list(o.bbox)}
                    for o in objects
                ]
            ),
            datetime.now(timezone.utc).isoformat(),
        ),
    )
    return objects
