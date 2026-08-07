from __future__ import annotations

from pathlib import Path

from PIL import Image

from ailbum.database import (
    get_person,
    list_people,
    merge_people,
    name_person,
    save_analysis,
)
from ailbum.metadata import collect_image_metadata
from ailbum.models import FaceRecord, PersonRecord, PhotoRecord
from ailbum.people import compose_person_faces


def _save_run(
    database: Path,
    source: Path,
    image_path: Path,
    run_id: str,
    embedding: list[float],
    bbox: tuple[int, int, int, int],
) -> PersonRecord:
    face = FaceRecord(
        face_id=f"{run_id}-face",
        bbox=bbox,
        confidence=0.95,
        person_cluster=1,
        embedding=embedding,
    )
    photo = PhotoRecord(
        photo_id=f"{run_id}-photo",
        path=str(image_path.resolve()),
        width=240,
        height=180,
        taken_at=None,
        sharpness=100.0,
        exposure=1.0,
        quality=1.0,
        is_blurry=False,
        selected=True,
        faces=[face],
    )
    person = PersonRecord(
        cluster_id=1,
        face_ids=[face.face_id],
        photo_ids=[photo.photo_id],
        embedding_model="test-model",
        centroid=embedding,
    )
    manifest: dict[str, object] = {
        "run_id": run_id,
        "started_at": "2026-08-07T10:00:00+00:00",
        "generated_at": "2026-08-07T10:00:01+00:00",
        "face_backend": "test",
        "config": {},
        "summary": {"faces": 1, "people_groups": 1},
    }
    save_analysis(
        database,
        source,
        source / "output",
        manifest,
        [photo],
        [person],
        [collect_image_metadata(image_path, source)],
        0.8,
    )
    return person


def test_people_are_stable_across_runs_and_can_be_composed(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    image_path = source / "portrait.jpg"
    Image.new("RGB", (240, 180), (80, 120, 160)).save(image_path)
    database = tmp_path / "catalog.sqlite3"

    first = _save_run(database, source, image_path, "run-1", [1.0, 0.0], (20, 20, 80, 80))
    second = _save_run(
        database, source, image_path, "run-2", [0.999, 0.01], (20, 20, 80, 80)
    )

    assert first.person_id == second.person_id
    assert len(list_people(database)) == 1
    details = name_person(database, first.person_id or 0, "Alice")
    assert details["name"] == "Alice"
    assert details["face_count"] == 2

    contact_sheet = tmp_path / "alice.jpg"
    result = compose_person_faces(database, first.person_id or 0, contact_sheet)
    assert result["faces"] == 1
    assert contact_sheet.exists()


def test_people_can_be_merged(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    image_path = source / "portrait.jpg"
    Image.new("RGB", (240, 180), (80, 120, 160)).save(image_path)
    database = tmp_path / "catalog.sqlite3"

    target = _save_run(database, source, image_path, "run-1", [1.0, 0.0], (10, 10, 60, 60))
    source_person = _save_run(
        database, source, image_path, "run-2", [0.0, 1.0], (120, 30, 60, 60)
    )
    merged = merge_people(
        database, target.person_id or 0, [source_person.person_id or 0]
    )

    assert len(list_people(database)) == 1
    assert merged["face_count"] == 2
    assert get_person(database, target.person_id or 0)["id"] == target.person_id
