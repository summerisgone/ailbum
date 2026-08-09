import numpy as np

from ailbum.cv.semantics import SemanticAnalyzer, _rank_tags


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
