from __future__ import annotations

import argparse
import json
import re
import sqlite3
from dataclasses import fields
from pathlib import Path
from typing import Any

from ailbum.catalog import index_library
from ailbum.models import PipelineConfig
from ailbum.pipeline import analyze_library

PHOTO_PROGRESS = re.compile(r"^\[(\d+)/(\d+)\]\s*(.*)$")
STAGE_PROGRESS = re.compile(r"^Этап:\s*([^|]+)(?:\|(.*))?$")


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def progress(message: str, default_stage: str = "Анализ фотографий") -> None:
    stage_match = STAGE_PROGRESS.match(message)
    if stage_match:
        emit(
            {
                "type": "progress",
                "stage": stage_match.group(1).strip(),
                "detail": (stage_match.group(2) or "").strip(),
            }
        )
        return
    photo_match = PHOTO_PROGRESS.match(message)
    if photo_match:
        emit(
            {
                "type": "progress",
                "stage": default_stage,
                "current": int(photo_match.group(1)),
                "total": int(photo_match.group(2)),
                "detail": photo_match.group(3),
            }
        )
        return
    emit({"type": "progress", "stage": "Обработка", "detail": message})


def _latest_analysis(database: Path) -> dict[str, Any] | None:
    if not database.exists():
        return None
    connection = sqlite3.connect(database)
    try:
        row = connection.execute(
            """
            SELECT source, output, config_json
            FROM analysis_runs
            WHERE status = 'completed'
            ORDER BY completed_at DESC
            LIMIT 1
            """
        ).fetchone()
    finally:
        connection.close()
    if row is None:
        return None
    return {"source": row[0], "output": row[1], "config": json.loads(row[2])}


def _pipeline_config(raw: dict[str, Any] | None) -> PipelineConfig:
    values = raw or {}
    allowed = {field.name for field in fields(PipelineConfig)}
    filtered = {key: value for key, value in values.items() if key in allowed}
    for key in ("models_dir", "feature_cache_dir"):
        if filtered.get(key) is not None:
            filtered[key] = Path(filtered[key])
    return PipelineConfig(**filtered)


def run_index(database: Path, sources: list[Path]) -> dict[str, object]:
    summaries: list[dict[str, object]] = []
    for position, source in enumerate(sources, start=1):
        emit(
            {
                "type": "progress",
                "stage": "Добавление фотографий",
                "detail": f"Папка {position} из {len(sources)}: {source.name}",
            }
        )
        summary = index_library(
            source,
            database,
            recursive=True,
            progress=lambda message: progress(message, "Добавление фотографий"),
        )
        summaries.append({"source": str(source.resolve()), **summary})
    return {"sources": summaries}


def run_analysis(database: Path, source: Path | None, output: Path | None) -> dict[str, object]:
    previous = _latest_analysis(database)
    actual_source = source or (Path(previous["source"]) if previous else None)
    if actual_source is None:
        raise ValueError("Сначала перетащите папку с фотографиями")
    actual_output = output or (
        Path(previous["output"])
        if previous and source is None
        else database.parent / "analysis-output"
    )
    manifest = analyze_library(
        actual_source,
        actual_output,
        _pipeline_config(previous["config"] if previous else None),
        recursive=True,
        progress=progress,
        database=database,
    )
    return {"run_id": manifest["run_id"], "summary": manifest["summary"]}


def main() -> None:
    parser = argparse.ArgumentParser(description="Ailbum Electron background job")
    parser.add_argument("kind", choices=("index", "analyze"))
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--source", type=Path, action="append")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.kind == "index":
            if not args.source:
                raise ValueError("Не выбраны папки с фотографиями")
            result = run_index(args.database, args.source)
        else:
            if args.source and len(args.source) > 1:
                raise ValueError("Одновременно можно анализировать только одну папку")
            result = run_analysis(
                args.database,
                args.source[0] if args.source else None,
                args.output,
            )
        emit({"type": "complete", "result": result})
    except Exception as error:
        emit({"type": "error", "error": f"{type(error).__name__}: {error}"})
        raise SystemExit(2) from error


if __name__ == "__main__":
    main()
