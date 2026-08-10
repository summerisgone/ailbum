from pathlib import Path

from ailbum.story_evaluation import (
    AnnotatedStory,
    evaluate_story_groups,
    parse_story_annotations,
)


def test_annotation_parser_ignores_video(tmp_path: Path) -> None:
    path = tmp_path / "stories.md"
    path.write_text(
        "## Первая группа\na.jpg\nclip.mp4\nb.jpg\n\n## Вторая группа\nc.jpg\n",
        encoding="utf-8",
    )

    assert parse_story_annotations(path) == [
        AnnotatedStory("Первая группа", ("a.jpg", "b.jpg")),
        AnnotatedStory("Вторая группа", ("c.jpg",)),
    ]


def test_balanced_metrics_penalize_merging_small_groups() -> None:
    expected = [
        AnnotatedStory("Лобби отеля", ("a.jpg", "b.jpg")),
        AnnotatedStory("Аквапарк", ("c.jpg", "d.jpg")),
    ]
    predictions = {
        name: (1, "Отдых в отеле") for name in ("a.jpg", "b.jpg", "c.jpg", "d.jpg")
    }

    result = evaluate_story_groups(expected, predictions)

    assert result["macro_completeness"] == 1.0
    assert result["bcubed_precision"] == 0.5
    assert result["mixed_predicted_stories"] == 1


def test_perfect_grouping_scores_one() -> None:
    expected = [
        AnnotatedStory("Лобби", ("a.jpg", "b.jpg")),
        AnnotatedStory("Пляж", ("c.jpg", "d.jpg")),
    ]
    predictions = {
        "a.jpg": (1, "Лобби"),
        "b.jpg": (1, "Лобби"),
        "c.jpg": (2, "Пляж"),
        "d.jpg": (2, "Пляж"),
    }

    result = evaluate_story_groups(expected, predictions)

    assert result["pairwise_f1"] == 1.0
    assert result["bcubed_f1"] == 1.0
    assert result["mean_title_similarity"] == 1.0
