from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from ailbum.database import (
    connect,
    create_person_from_face,
    get_desktop_faces,
    get_desktop_people,
    get_person,
    list_people,
    merge_people,
    name_person,
    save_analysis,
    set_face_person,
)
from ailbum.desktop_bridge import _dispatch
from ailbum.metadata import collect_image_metadata
from ailbum.models import (
    ExpressionRecord,
    EyeStateRecord,
    FaceRecord,
    PersonRecord,
    PhotoRecord,
)
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
        eyes=EyeStateRecord(
            left="open",
            right="closed",
            left_open_probability=0.91,
            right_open_probability=0.12,
            both_open=False,
        ),
        expression=ExpressionRecord(
            label="happy",
            confidence=0.84,
            smile_probability=0.84,
            scores={"happy": 0.84, "neutral": 0.16},
        ),
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
    assert details["faces"][0]["left_eye_state"] == "open"
    assert details["faces"][0]["right_eye_state"] == "closed"
    assert details["faces"][0]["both_eyes_open"] is False
    assert details["faces"][0]["expression"] == "happy"
    assert details["faces"][0]["expression_scores"]["happy"] == 0.84

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


def _two_people(tmp_path: Path) -> tuple[Path, int, int]:
    source = tmp_path / "photos"
    source.mkdir()
    image_path = source / "portrait.jpg"
    Image.new("RGB", (240, 180), (80, 120, 160)).save(image_path)
    database = tmp_path / "catalog.sqlite3"
    first = _save_run(database, source, image_path, "run-1", [1.0, 0.0], (10, 10, 60, 60))
    second = _save_run(database, source, image_path, "run-2", [0.0, 1.0], (120, 30, 60, 60))
    return database, first.person_id or 0, second.person_id or 0


def test_merge_keeps_target_name(tmp_path: Path) -> None:
    database, target_id, source_id = _two_people(tmp_path)
    name_person(database, target_id, "Ирина")
    name_person(database, source_id, "Ира")

    merged = merge_people(database, target_id, [source_id])

    assert merged["name"] == "Ирина"


def test_merge_into_unnamed_target_inherits_source_name(tmp_path: Path) -> None:
    database, target_id, source_id = _two_people(tmp_path)
    name_person(database, source_id, "Ирина")

    merged = merge_people(database, target_id, [source_id])

    assert merged["name"] == "Ирина"
    assert merged["face_count"] == 2


def test_merge_rejects_people_from_different_models(tmp_path: Path) -> None:
    database, target_id, source_id = _two_people(tmp_path)
    with connect(database) as connection:
        connection.execute(
            "UPDATE people SET embedding_model = 'other-model' WHERE id = ?", (source_id,)
        )

    with pytest.raises(ValueError, match="разных моделей"):
        merge_people(database, target_id, [source_id])

    assert len(list_people(database)) == 2


def test_desktop_bridge_merges_person_into_target(tmp_path: Path) -> None:
    database, target_id, source_id = _two_people(tmp_path)
    name_person(database, target_id, "Ирина")

    merged = _dispatch(
        database, "person.merge", {"source_id": source_id, "target_id": target_id}
    )

    assert merged["id"] == target_id
    assert merged["face_count"] == 2
    assert [person["id"] for person in list_people(database)] == [target_id]


def test_desktop_editor_can_reassign_and_create_people(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    image_path = source / "portrait.jpg"
    Image.new("RGB", (240, 180), (80, 120, 160)).save(image_path)
    database = tmp_path / "catalog.sqlite3"

    first = _save_run(database, source, image_path, "run-1", [1.0, 0.0], (10, 10, 60, 60))
    second = _save_run(database, source, image_path, "run-2", [0.0, 1.0], (120, 30, 60, 60))
    first_id = first.person_id or 0
    second_id = second.person_id or 0
    face_id = int(get_desktop_faces(database, first_id)["faces"][0]["id"])

    set_face_person(database, face_id, second_id)
    people = get_desktop_people(database)
    counts = {person["id"]: person["face_count"] for person in people["people"]}
    assert counts[first_id] == 0
    assert counts[second_id] == 2

    set_face_person(database, face_id, None)
    assert get_desktop_people(database)["unassigned_count"] == 1
    created = create_person_from_face(database, face_id, "New person")

    assert created["id"] not in {first_id, second_id}
    assert created["name"] == "New person"
    assert get_desktop_people(database)["unassigned_count"] == 0
