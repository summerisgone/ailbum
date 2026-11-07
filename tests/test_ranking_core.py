from __future__ import annotations

import sqlite3

import numpy as np

from ailbum.models import (
    ColorRecord,
    CompositionRecord,
    ExpressionRecord,
    EyeStateRecord,
    FaceRecord,
    PhotoRecord,
    SemanticRecord,
)
from ailbum.ranking import features
from ailbum.ranking.model import LogisticModel

DDL = """
CREATE TABLE photo_analysis (run_id TEXT, image_id INTEGER, photo_id TEXT, sharpness REAL,
 exposure REAL, quality REAL, aesthetic_score REAL, composition_score REAL, rule_of_thirds REAL,
 crop_risk REAL, color_balance REAL, color_harmony REAL, is_blurry INTEGER, similar_cluster INTEGER,
 error TEXT);
CREATE TABLE faces (run_id TEXT, image_id INTEGER, left_eye_state TEXT, right_eye_state TEXT,
 smile_probability REAL, person_id INTEGER);
"""


def _record(full: bool) -> PhotoRecord:
    rec = PhotoRecord("p", "/p.jpg", 10, 10, None, 120.0, 0.8, 0.7, False)
    if full:
        rec.composition = CompositionRecord(0.5, 0.4, 0.3, 0.2, 0.6)
        rec.color = ColorRecord(0.9, 0.8, 0.1)
        rec.semantics = SemanticRecord(0.75, "m")
        rec.faces = [
            FaceRecord("f1", (0, 0, 5, 5), 0.9, person_id=3,
                       eyes=EyeStateRecord(left="closed", right="open"),
                       expression=ExpressionRecord("happy", 0.9, 0.6, {})),
            FaceRecord("f2", (0, 0, 5, 5), 0.9, expression=ExpressionRecord("n", 0.9, 0.2, {})),
        ]
    return rec


def _insert(conn, run, image_id, rec, cluster):
    c, col, s = rec.composition, rec.color, rec.semantics
    conn.execute(
        "INSERT INTO photo_analysis VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
        (run, image_id, rec.photo_id, rec.sharpness, rec.exposure, rec.quality,
         s.aesthetic_score if s else None, c.score if c else None,
         c.rule_of_thirds if c else None, c.crop_risk if c else None,
         col.balance if col else None, col.harmony if col else None,
         int(rec.is_blurry), cluster),
    )
    for f in rec.faces:
        conn.execute(
            "INSERT INTO faces VALUES (?,?,?,?,?,?)",
            (run, image_id, f.eyes.left if f.eyes else None, f.eyes.right if f.eyes else None,
             f.expression.smile_probability if f.expression else None, f.person_id),
        )


def test_missing_values_zero_with_flag():
    v = dict(zip(features.FEATURE_NAMES, features.from_record(_record(False), 1, 0)))
    assert v["aesthetic_score"] == 0 and v["has_aesthetic"] == 0
    assert v["composition_score"] == 0 and v["has_composition"] == 0
    assert v["smile_max"] == 0 and v["has_smile"] == 0
    full = dict(zip(features.FEATURE_NAMES, features.from_record(_record(True), 2, 1)))
    assert full["has_aesthetic"] == 1 and full["closed_eyes_count"] == 1
    assert full["smile_max"] == 0.6 and full["known_people_count"] == 1
    assert full["face_count"] == 2 and full["group_size"] == 2 and full["group_rank"] == 1


def test_from_record_equals_from_rows():
    conn = sqlite3.connect(":memory:")
    conn.executescript(DDL)
    a, b, c = _record(True), _record(False), _record(True)
    b.quality = 0.9
    c.quality = 0.1
    _insert(conn, "r", 1, a, 5)
    _insert(conn, "r", 2, b, 5)
    _insert(conn, "r", 3, c, None)
    rows = features.from_rows(conn, "r")
    assert np.array_equal(rows[1], features.from_record(a, 2, 1))
    assert np.array_equal(rows[2], features.from_record(b, 2, 0))
    assert np.array_equal(rows[3], features.from_record(c, 1, 0))
    assert len(rows[1]) == len(features.FEATURE_NAMES)


def test_zero_variance_column_no_nan():
    x = np.array([[1.0, 5.0], [2.0, 5.0], [3.0, 5.0], [4.0, 5.0]])
    y = np.array([0, 0, 1, 1])
    m = LogisticModel.fit(x, y)
    s = m.score(x)
    assert not np.isnan(s).any() and not np.isnan(m.weights).any()
    assert m.std[1] == 1.0 and s[3] > s[0]


def test_fit_separable_converges():
    rng = np.random.default_rng(0)
    x = np.vstack([rng.normal(-3, 0.5, (30, 3)), rng.normal(3, 0.5, (30, 3))])
    y = np.array([0] * 30 + [1] * 30)
    m = LogisticModel.fit(x, y)
    s = m.score(x)
    assert np.isfinite(m.weights).all() and np.isfinite(s).all()
    assert ((s > 0.5) == (y == 1)).all()


def test_json_roundtrip():
    x = np.array([[0.0, 1.0], [1.0, 0.0], [2.0, 1.0], [3.0, 0.0]])
    m = LogisticModel.fit(x, np.array([0, 0, 1, 1]))
    data = m.to_json()
    m2 = LogisticModel.from_json(data)
    assert data["feature_version"] == features.FEATURE_VERSION
    assert data["feature_names"] == list(features.FEATURE_NAMES)
    assert np.allclose(m.score(x), m2.score(x))
