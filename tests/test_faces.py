from __future__ import annotations

import numpy as np

from ailbum.cv.faces import EXPRESSION_LABELS, FaceAnalyzer, _as_probabilities


class _FakeNet:
    def __init__(self, output: list[float]) -> None:
        self.output = np.asarray(output, dtype=np.float32)
        self.inputs: list[tuple[np.ndarray, str]] = []

    def setInput(self, blob: np.ndarray, name: str) -> None:
        self.inputs.append((blob, name))

    def forward(self, name: str) -> np.ndarray:
        return self.output.copy()


def test_classifier_outputs_eye_state_expression_and_smile_probability() -> None:
    analyzer = object.__new__(FaceAnalyzer)
    analyzer.backend = "dnn"
    analyzer.eye_state_net = _FakeNet([0.82, 0.18])
    analyzer.expression_net = _FakeNet([-2.0, -3.0, -4.0, 5.0, 0.0, -1.0, -2.0])

    attributes = analyzer.classify_attributes(np.zeros((112, 112, 3), dtype=np.uint8))

    assert attributes.left_eye == "open"
    assert attributes.right_eye == "open"
    assert attributes.left_eye_open_probability == 0.82
    assert attributes.right_eye_open_probability == 0.82
    assert attributes.both_eyes_open is True
    assert attributes.expression == "happy"
    assert attributes.expression_scores is not None
    assert set(attributes.expression_scores) == set(EXPRESSION_LABELS)
    assert attributes.smile_probability == attributes.expression_scores["happy"]
    assert len(analyzer.eye_state_net.inputs) == 2
    assert analyzer.eye_state_net.inputs[0][1] == "input.1"
    assert analyzer.expression_net.inputs[0][1] == "data"


def test_probability_postprocessing_preserves_softmax_and_normalizes_logits() -> None:
    probabilities = _as_probabilities(np.array([0.7, 0.3], dtype=np.float32))
    logits = _as_probabilities(np.array([2.0, 1.0], dtype=np.float32))

    assert np.allclose(probabilities, [0.7, 0.3])
    assert np.isclose(logits.sum(), 1.0)
    assert logits[0] > logits[1]
