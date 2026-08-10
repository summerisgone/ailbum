from __future__ import annotations

import re
import sqlite3
from collections import Counter
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

_VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v"}


@dataclass(frozen=True, slots=True)
class AnnotatedStory:
    title: str
    file_names: tuple[str, ...]


def parse_story_annotations(path: Path) -> list[AnnotatedStory]:
    """Parse Markdown headings followed by one media filename per line."""
    stories: list[AnnotatedStory] = []
    title: str | None = None
    names: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip().strip("*").strip()
        if line.startswith("## "):
            if title is not None and names:
                stories.append(AnnotatedStory(title, tuple(dict.fromkeys(names))))
            title = line[3:].strip()
            names = []
        elif line and title is not None:
            candidate = line.strip("`").strip()
            if Path(candidate).suffix.casefold() not in _VIDEO_EXTENSIONS:
                names.append(candidate)
    if title is not None and names:
        stories.append(AnnotatedStory(title, tuple(dict.fromkeys(names))))
    return stories


def evaluate_database_stories(
    database: Path, annotations: Path, run_id: str | None = None
) -> dict[str, Any]:
    expected = parse_story_annotations(annotations)
    with sqlite3.connect(database) as connection:
        connection.row_factory = sqlite3.Row
        if run_id is None:
            row = connection.execute(
                "SELECT id FROM analysis_runs ORDER BY completed_at DESC LIMIT 1"
            ).fetchone()
            if row is None:
                raise ValueError("В базе нет запусков анализа")
            run_id = str(row["id"])
        rows = connection.execute(
            """
            SELECT i.file_name, pa.story_id, s.title
            FROM photo_analysis AS pa
            JOIN images AS i ON i.id = pa.image_id
            LEFT JOIN stories AS s
              ON s.run_id = pa.run_id AND s.story_id = pa.story_id
            WHERE pa.run_id = ?
            """,
            (run_id,),
        ).fetchall()
    predictions = {
        str(row["file_name"]): (int(row["story_id"]), str(row["title"] or ""))
        for row in rows
        if row["story_id"] is not None
    }
    return evaluate_story_groups(expected, predictions, run_id=run_id)


def evaluate_story_groups(
    expected: list[AnnotatedStory],
    predictions: dict[str, tuple[int, str]],
    *,
    run_id: str | None = None,
) -> dict[str, Any]:
    truth_by_file = {
        file_name: truth_id
        for truth_id, story in enumerate(expected)
        for file_name in story.file_names
    }
    found = [file_name for file_name in truth_by_file if file_name in predictions]
    truth_sizes = Counter(truth_by_file[file_name] for file_name in found)
    predicted_sizes = Counter(predictions[file_name][0] for file_name in found)
    contingency = Counter(
        (truth_by_file[file_name], predictions[file_name][0]) for file_name in found
    )

    true_pairs = sum(_pairs(size) for size in truth_sizes.values())
    predicted_pairs = sum(_pairs(size) for size in predicted_sizes.values())
    matching_pairs = sum(_pairs(size) for size in contingency.values())
    pair_precision = _ratio(matching_pairs, predicted_pairs)
    pair_recall = _ratio(matching_pairs, true_pairs)

    b_precision: list[float] = []
    b_recall: list[float] = []
    for file_name in found:
        truth_id = truth_by_file[file_name]
        predicted_id = predictions[file_name][0]
        intersection = contingency[(truth_id, predicted_id)]
        b_precision.append(intersection / predicted_sizes[predicted_id])
        b_recall.append(intersection / truth_sizes[truth_id])

    per_story: list[dict[str, Any]] = []
    title_scores: list[float] = []
    for truth_id, story in enumerate(expected):
        story_found = [name for name in story.file_names if name in predictions]
        assignments = Counter(predictions[name][0] for name in story_found)
        dominant_story_id = assignments.most_common(1)[0][0] if assignments else None
        completeness = (
            assignments[dominant_story_id] / len(story_found)
            if dominant_story_id is not None
            else 0.0
        )
        predicted_title = (
            next(
                predictions[name][1]
                for name in story_found
                if predictions[name][0] == dominant_story_id
            )
            if dominant_story_id is not None
            else ""
        )
        title_similarity = _title_similarity(story.title, predicted_title)
        if predicted_title:
            title_scores.append(title_similarity)
        per_story.append(
            {
                "expected_title": story.title,
                "photos": len(story.file_names),
                "found": len(story_found),
                "predicted_story_ids": dict(sorted(assignments.items())),
                "dominant_story_id": dominant_story_id,
                "completeness": round(completeness, 4),
                "predicted_title": predicted_title,
                "title_similarity": round(title_similarity, 4),
            }
        )

    homogeneity = [
        max(
            contingency[(truth_id, predicted_id)]
            for truth_id in truth_sizes
        )
        / size
        for predicted_id, size in predicted_sizes.items()
    ]
    completeness_values = [story["completeness"] for story in per_story]
    b_precision_mean = _mean(b_precision)
    b_recall_mean = _mean(b_recall)
    return {
        "run_id": run_id,
        "annotated_stories": len(expected),
        "annotated_photos": len(truth_by_file),
        "matched_photos": len(found),
        "coverage": round(_ratio(len(found), len(truth_by_file)), 4),
        "pairwise_precision": round(pair_precision, 4),
        "pairwise_recall": round(pair_recall, 4),
        "pairwise_f1": round(_f1(pair_precision, pair_recall), 4),
        "bcubed_precision": round(b_precision_mean, 4),
        "bcubed_recall": round(b_recall_mean, 4),
        "bcubed_f1": round(_f1(b_precision_mean, b_recall_mean), 4),
        "macro_completeness": round(_mean(completeness_values), 4),
        "minimum_completeness": round(min(completeness_values, default=0.0), 4),
        "macro_homogeneity": round(_mean(homogeneity), 4),
        "complete_stories": sum(value == 1.0 for value in completeness_values),
        "mixed_predicted_stories": sum(value < 1.0 for value in homogeneity),
        "mean_title_similarity": round(_mean(title_scores), 4),
        "stories": per_story,
    }


def _pairs(size: int) -> int:
    return size * (size - 1) // 2


def _ratio(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 0.0


def _f1(precision: float, recall: float) -> float:
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def _title_similarity(expected: str, predicted: str) -> float:
    def normalize(value: str) -> str:
        return " ".join(re.findall(r"[a-zа-яё0-9]+", value.casefold()))

    left = normalize(expected)
    right = normalize(predicted)
    return SequenceMatcher(None, left, right).ratio() if left and right else 0.0
