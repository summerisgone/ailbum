from __future__ import annotations

import pytest

from ailbum.layout import preferences
from ailbum.layout.facts import PhotoFacts
from ailbum.layout.types import Rect, Region


def photo(image_id, *regions):
    return PhotoFacts(image_id, 1.5, f"image:{image_id}", 1, None, 0.5, True, tuple(regions))


FACE = Region(Rect(0.3, 0.2, 0.4, 0.5), 1.0, True, "face")
SMALL_FACE = Region(Rect(0.3, 0.2, 0.05, 0.05), 1.0, True, "face")
PERSON = Region(Rect(0.1, 0.1, 0.2, 0.6), 0.6, False, "person")


@pytest.mark.parametrize(
    ("prompt", "weights"),
    [
        ("приоритет лицам и крупным планам", {"faces": 1.0, "closeups": 1.0}),
        ("лица, а не пейзажи", {"faces": 1.0, "landscapes": -1.0}),
        ("больше пейзажей, меньше людей", {"landscapes": 1.0, "faces": -1.0}),
        ("природа и виды", {"landscapes": 1.0}),
        ("что-нибудь красивое", {}),
        ("", {}),
    ],
)
def test_parse(prompt, weights):
    assert preferences.parse(prompt) == weights


def test_describe_in_axis_order():
    assert preferences.describe({"landscapes": -1.0, "faces": 1.0}) == [
        "больше лиц", "меньше пейзажей"]


def test_features():
    assert preferences.features(photo(1, FACE)) == {
        "faces": 1.0, "closeups": 1.0, "landscapes": 0.0}
    assert preferences.features(photo(2, SMALL_FACE))["closeups"] < 0.1
    assert preferences.features(photo(3, PERSON))["faces"] == 0.5
    assert preferences.features(photo(4))["landscapes"] == 1.0


def test_apply_shifts_rank():
    portrait, view = photo(1, FACE), photo(2)
    faces = preferences.apply([portrait, view], {"faces": 1.0})
    assert faces[0].rank > faces[1].rank == 0.5
    views = preferences.apply([portrait, view], {"landscapes": 1.0})
    assert views[1].rank > views[0].rank
    assert preferences.apply([portrait], {}) == [portrait]
