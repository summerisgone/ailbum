from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field

import numpy as np

from ailbum.ranking import features, store
from ailbum.ranking.labels import EXPLICIT, group_pairs
from ailbum.ranking.model import LogisticModel

MIN_PAIRS = 50
MIN_ALBUMS = 2
MIN_POINTWISE_EVENTS = 5
REASON = f"нужно не меньше {MIN_PAIRS} пар из {MIN_ALBUMS} альбомов"
POINTWISE_REASON = f"нужно не меньше {MIN_ALBUMS} альбомов с {MIN_POINTWISE_EVENTS} ручными действиями"
QUALITY = features.FEATURE_NAMES.index("quality")


@dataclass
class AlbumData:
    album_id: int
    vectors: dict[int, np.ndarray]
    final: set[int]
    pairs: list[tuple[int, int]]
    explicit_events: int
    shas: set[str] = field(default_factory=set)
    touched: list[list[int]] = field(default_factory=list)


def _load(connection: sqlite3.Connection) -> list[AlbumData]:
    result = []
    albums = connection.execute("SELECT id, run_id FROM albums WHERE run_id IS NOT NULL ORDER BY id").fetchall()
    for album_id, run_id in albums:
        vectors = features.from_rows(connection, run_id)
        if not vectors:
            continue
        final = {
            r[0]
            for r in connection.execute("SELECT image_id FROM album_photos WHERE album_id = ?", (album_id,))
        } & set(vectors)
        events = [
            {"image_id": r[0], "source": r[1], "action": r[2]}
            for r in connection.execute(
                "SELECT image_id, source, action FROM selection_events WHERE album_id = ? ORDER BY id",
                (album_id,),
            )
        ]
        groups: dict[int, list[int]] = {}
        for image_id, cluster in connection.execute(
            "SELECT image_id, similar_cluster FROM photo_analysis"
            " WHERE run_id = ? AND error IS NULL AND similar_cluster IS NOT NULL",
            (run_id,),
        ):
            groups.setdefault(cluster, []).append(image_id)
        shas = {
            r[0]
            for r in connection.execute(
                "SELECT sha256 FROM images WHERE id IN"
                " (SELECT image_id FROM photo_analysis WHERE run_id = ?)",
                (run_id,),
            )
        }
        touched = [
            members for cluster, members in groups.items()
            if group_pairs(events, final, {cluster: members})
        ]
        result.append(
            AlbumData(
                album_id, vectors, final, group_pairs(events, final, groups),
                sum(e["source"] in EXPLICIT for e in events), shas, touched,
            )
        )
    return result


def _components(albums: list[AlbumData]) -> list[list[AlbumData]]:
    """Albums sharing any sha256 stay together so duplicates never straddle train and test."""
    parent = list(range(len(albums)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    owner: dict[str, int] = {}
    for i, album in enumerate(albums):
        for sha in album.shas:
            j = owner.setdefault(sha, i)
            parent[find(i)] = find(j)
    buckets: dict[int, list[AlbumData]] = {}
    for i, album in enumerate(albums):
        buckets.setdefault(find(i), []).append(album)
    return list(buckets.values())


def _pairwise_xy(albums: list[AlbumData]) -> tuple[np.ndarray, np.ndarray]:
    rows, labels = [], []
    for album in albums:
        for w, l in album.pairs:
            diff = album.vectors[w] - album.vectors[l]
            rows += [diff, -diff]
            labels += [1.0, 0.0]
    return np.array(rows), np.array(labels)


def _pairwise_hits(model: LogisticModel | None, albums: list[AlbumData]) -> tuple[int, int]:
    """Top-1 hits and group count over touched groups (model=None means max quality)."""
    hits = total = 0
    for album in albums:
        for members in album.touched:
            order = sorted(members)
            vecs = np.array([album.vectors[i] for i in order])
            scores = vecs[:, QUALITY] if model is None else model.score(vecs)
            hits += order[int(np.argmax(scores))] in album.final
            total += 1
    return hits, total


def _train_pairwise(albums: list[AlbumData]) -> tuple[LogisticModel, dict] | tuple[None, str]:
    usable = [a for a in albums if a.pairs]
    pairs = sum(len(a.pairs) for a in usable)
    if pairs < MIN_PAIRS or len(usable) < MIN_ALBUMS:
        return None, REASON
    folds = _components(usable)
    metrics = {"pairs": pairs, "albums": len(usable), "accuracy": None, "baseline": None}
    if len(folds) >= 2:
        hits = base_hits = total = 0
        for i, fold in enumerate(folds):
            rest = [a for j, f in enumerate(folds) if j != i for a in f]
            x, y = _pairwise_xy(rest)
            if len(y) == 0:
                continue
            model = LogisticModel.fit(x, y)
            h, t = _pairwise_hits(model, fold)
            hits += h
            total += t
            base_hits += _pairwise_hits(None, fold)[0]
        if total:
            metrics.update(accuracy=hits / total, baseline=base_hits / total, groups=total)
    x, y = _pairwise_xy(usable)
    return LogisticModel.fit(x, y), metrics


def _pointwise_xy(albums: list[AlbumData]) -> tuple[np.ndarray, np.ndarray]:
    rows, labels = [], []
    for album in albums:
        for image_id in sorted(album.vectors):
            rows.append(album.vectors[image_id])
            labels.append(1.0 if image_id in album.final else 0.0)
    return np.array(rows), np.array(labels)


def _precision(model: LogisticModel | None, albums: list[AlbumData]) -> list[float]:
    result = []
    for album in albums:
        ids = sorted(album.vectors)
        k = len(album.final)
        if k == 0:
            continue
        vecs = np.array([album.vectors[i] for i in ids])
        scores = vecs[:, QUALITY] if model is None else model.score(vecs)
        top = [ids[i] for i in np.argsort(-scores, kind="stable")[:k]]
        result.append(len(set(top) & album.final) / k)
    return result


def _train_pointwise(albums: list[AlbumData]) -> tuple[LogisticModel, dict] | tuple[None, str]:
    usable = [a for a in albums if a.explicit_events >= MIN_POINTWISE_EVENTS and a.final]
    if len(usable) < MIN_ALBUMS:
        return None, POINTWISE_REASON
    folds = _components(usable)
    metrics = {"albums": len(usable), "precision": None, "baseline": None}
    if len(folds) >= 2:
        got: list[float] = []
        base: list[float] = []
        for i, fold in enumerate(folds):
            rest = [a for j, f in enumerate(folds) if j != i for a in f]
            x, y = _pointwise_xy(rest)
            model = LogisticModel.fit(x, y)
            got += _precision(model, fold)
            base += _precision(None, fold)
        if got:
            metrics.update(precision=float(np.mean(got)), baseline=float(np.mean(base)))
    x, y = _pointwise_xy(usable)
    return LogisticModel.fit(x, y), metrics


def _better(metrics: dict, key: str) -> bool:
    return metrics[key] is not None and metrics[key] >= metrics["baseline"]


def _run(connection: sqlite3.Connection, save: bool) -> dict:
    albums = _load(connection)
    out: dict = {"pairwise": None, "pointwise": None, "reason": None}
    reasons = []
    for kind, trainer, key in (
        ("pairwise", _train_pairwise, "accuracy"),
        ("pointwise", _train_pointwise, "precision"),
    ):
        model, info = trainer(albums)
        if model is None:
            reasons.append(info)
            continue
        info["active"] = _better(info, key)
        if save:
            info["id"] = store.save_model(connection, kind, model, info, info["active"])
        out[kind] = info
    if out["pairwise"] is None and out["pointwise"] is None:
        out["reason"] = reasons[0]
    return out


def train(connection: sqlite3.Connection) -> dict:
    return _run(connection, True)


def evaluate(connection: sqlite3.Connection) -> dict:
    return _run(connection, False)


def status(connection: sqlite3.Connection) -> dict:
    albums = _load(connection)
    pairs = sum(len(a.pairs) for a in albums)
    contributing = sum(1 for a in albums if a.pairs)
    result: dict = {"pairs": pairs, "albums": contributing}
    for kind in ("pairwise", "pointwise"):
        row = store.active_row(connection, kind)
        result[kind] = None if row is None else {"id": row[0], **json.loads(row[3])}
    enough = pairs >= MIN_PAIRS and contributing >= MIN_ALBUMS
    result["reason"] = None if enough else REASON
    return result
