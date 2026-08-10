import numpy as np

from ailbum.cv.semantics import OBJECT_PROMPTS, SCENE_PROMPTS, SemanticAnalyzer, _rank_tags


def test_disabled_semantic_backend_returns_empty_record() -> None:
    analyzer = SemanticAnalyzer("off", "unused", threshold=0.15, top_k=3)

    result = analyzer.analyze(np.zeros((10, 10, 3), dtype=np.uint8))

    assert analyzer.available is False
    assert result.aesthetic_score is None
    assert result.scenes == []
    assert result.objects == []


def test_semantic_tags_respect_threshold_and_top_k() -> None:
    tags = _rank_tags(("first", "second", "third"), np.array([3.0, 2.0, 0.0]), 0.1, 2)

    assert [tag.label for tag in tags] == ["first", "second"]
    assert tags[0].confidence > tags[1].confidence


def test_semantic_taxonomy_includes_hookah_as_activity_and_object() -> None:
    assert "hookah" in SCENE_PROMPTS
    assert "hookah" in OBJECT_PROMPTS
    assert "hoses" in SCENE_PROMPTS["hookah"]
    assert "glass base" in OBJECT_PROMPTS["hookah"]


def test_semantic_taxonomy_distinguishes_user_story_types() -> None:
    assert {
        "hotel_lobby",
        "waterpark",
        "pool",
        "diving",
        "seaside_photo_session",
        "water_sports",
        "dinner",
        "night_sky",
        "boat_trip",
        "mountain_trip",
        "hotel_exterior",
    } <= SCENE_PROMPTS.keys()
