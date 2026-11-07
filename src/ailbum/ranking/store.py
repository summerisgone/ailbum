from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone

from ailbum.ranking import features
from ailbum.ranking.model import LogisticModel


def save_model(
    connection: sqlite3.Connection, kind: str, model: LogisticModel, metrics: dict, active: bool
) -> int:
    if active:
        connection.execute("UPDATE ranking_models SET active = 0 WHERE kind = ?", (kind,))
    cursor = connection.execute(
        """
        INSERT INTO ranking_models (kind, feature_version, model_json, metrics_json, active, trained_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (
            kind,
            model.feature_version,
            json.dumps(model.to_json()),
            json.dumps(metrics, ensure_ascii=False),
            int(active),
            datetime.now(timezone.utc).isoformat(),
        ),
    )
    return int(cursor.lastrowid)


def active_row(connection: sqlite3.Connection, kind: str):
    row = connection.execute(
        """
        SELECT id, feature_version, model_json, metrics_json FROM ranking_models
        WHERE kind = ? AND active = 1 ORDER BY id DESC LIMIT 1
        """,
        (kind,),
    ).fetchone()
    if row is None or row[1] != features.FEATURE_VERSION:
        return None
    return row


def active_model(connection: sqlite3.Connection, kind: str) -> LogisticModel | None:
    row = active_row(connection, kind)
    if row is None:
        return None
    model = LogisticModel.from_json(json.loads(row[2]))
    model.id = row[0]
    return model
