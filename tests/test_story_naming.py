from pathlib import Path
from typing import Any

from PIL import Image

from ailbum.models import StoryRecord
from ailbum.story_naming import StoryNamer, _parse_title, _title_score


def test_story_namer_uses_local_multimodal_response(
    tmp_path: Path, monkeypatch: Any
) -> None:
    photo = tmp_path / "beach.jpg"
    Image.new("RGB", (64, 48), (20, 40, 80)).save(photo)
    story = StoryRecord(
        story_id=1,
        title="Ночной пляж",
        photo_ids=["photo-1"],
        started_at=None,
        ended_at=None,
        representative_photo_id="photo-1",
        scene_labels=["night", "beach"],
    )

    def fake_request(
        url: str,
        payload: dict[str, Any] | None = None,
        *,
        timeout: float,
    ) -> dict[str, Any]:
        assert timeout > 0
        if url.endswith("/models"):
            return {"data": [{"id": "test-vlm"}]}
        assert payload is not None
        content = payload["messages"][0]["content"]
        assert any(item["type"] == "image_url" for item in content)
        return {
            "choices": [
                {"message": {"content": '{"title":"Ночная фотосессия на пляже"}'}}
            ]
        }

    monkeypatch.setattr("ailbum.story_naming._request_json", fake_request)
    namer = StoryNamer(model="test-vlm")

    namer.refine([story], {"photo-1": str(photo)})

    assert story.title == "Ночная фотосессия на пляже"
    assert story.naming_model == "test-vlm"
    assert namer.backend == "lmstudio"


def test_generic_vlm_title_is_rejected() -> None:
    assert _parse_title('{"title":"Событие"}') is None
    assert _parse_title('{"title":"Дай лайфхаки для дайвинга"}') is None
    assert _parse_title('```json\n{"title":"Прогулка у моря"}\n```') == "Прогулка у моря"


def test_specific_rule_title_can_beat_weaker_vlm_title() -> None:
    story = StoryRecord(
        story_id=1,
        title="Ночная фотосессия на пляже",
        photo_ids=[],
        started_at=None,
        ended_at=None,
        representative_photo_id="photo-1",
        scene_labels=["night", "beach"],
        object_labels=["people"],
    )

    assert _title_score(story.title, story) > _title_score("Луна на пляже", story)
