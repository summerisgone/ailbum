from __future__ import annotations

import sqlite3

import numpy as np

from ailbum.models import PhotoRecord

FEATURE_VERSION = 1
FEATURE_NAMES = (
    "quality",
    "sharpness",
    "exposure",
    "aesthetic_score",
    "has_aesthetic",
    "composition_score",
    "has_composition",
    "rule_of_thirds",
    "color_balance",
    "color_harmony",
    "crop_risk",
    "face_count",
    "closed_eyes_count",
    "smile_max",
    "has_smile",
    "known_people_count",
    "is_blurry",
    "group_size",
    "group_rank",
)


def _vector(
    quality, sharpness, exposure, aesthetic, composition, thirds, balance, harmony,
    crop_risk, face_count, closed, smile, known, blurry, group_size, group_rank,
) -> np.ndarray:
    def val(x):
        return 0.0 if x is None else float(x)

    return np.array(
        [
            val(quality), val(sharpness), val(exposure),
            val(aesthetic), aesthetic is not None,
            val(composition), composition is not None,
            val(thirds), val(balance), val(harmony), val(crop_risk),
            face_count, closed, val(smile), smile is not None,
            known, bool(blurry), group_size, group_rank,
        ],
        dtype=np.float64,
    )


def from_record(record: PhotoRecord, group_size: int, group_rank: int) -> np.ndarray:
    composition, color, semantics = record.composition, record.color, record.semantics
    smiles = [f.expression.smile_probability for f in record.faces if f.expression is not None]
    closed = sum(
        1 for f in record.faces
        if f.eyes is not None and "closed" in (f.eyes.left, f.eyes.right)
    )
    return _vector(
        record.quality, record.sharpness, record.exposure,
        semantics.aesthetic_score if semantics else None,
        composition.score if composition else None,
        composition.rule_of_thirds if composition else None,
        color.balance if color else None,
        color.harmony if color else None,
        composition.crop_risk if composition else None,
        len(record.faces), closed,
        max(smiles) if smiles else None,
        sum(1 for f in record.faces if f.person_id is not None),
        record.is_blurry, group_size, group_rank,
    )


def from_rows(connection: sqlite3.Connection, run_id: str) -> dict[int, np.ndarray]:
    """Feature vectors by image_id for one run, identical to from_record for the same photo."""
    photos = connection.execute(
        """
        SELECT image_id, quality, sharpness, exposure, aesthetic_score, composition_score,
               rule_of_thirds, color_balance, color_harmony, crop_risk, is_blurry, similar_cluster
        FROM photo_analysis WHERE run_id = ? AND error IS NULL
        """,
        (run_id,),
    ).fetchall()
    faces: dict[int, list[tuple]] = {}
    for row in connection.execute(
        """
        SELECT image_id, left_eye_state, right_eye_state, smile_probability, person_id
        FROM faces WHERE run_id = ?
        """,
        (run_id,),
    ):
        faces.setdefault(row[0], []).append(tuple(row))
    clusters: dict[int, list[tuple[float, int]]] = {}
    for row in photos:
        if row[11] is not None:
            clusters.setdefault(row[11], []).append((-row[1], row[0]))
    ranks: dict[int, tuple[int, int]] = {}
    for members in clusters.values():
        for rank, (_, image_id) in enumerate(sorted(members)):
            ranks[image_id] = (len(members), rank)
    result = {}
    for row in photos:
        image_id = row[0]
        rows = faces.get(image_id, [])
        smiles = [f[3] for f in rows if f[3] is not None]
        size, rank = ranks.get(image_id, (1, 0))
        result[image_id] = _vector(
            row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9],
            len(rows),
            sum(1 for f in rows if "closed" in (f[1], f[2])),
            max(smiles) if smiles else None,
            sum(1 for f in rows if f[4] is not None),
            row[10], size, rank,
        )
    return result
