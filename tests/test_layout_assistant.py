from __future__ import annotations

import importlib
import os
import sys
import types
from dataclasses import dataclass
from io import BytesIO

import pytest
from PIL import Image

from ailbum.layout import assistant as assistant_module
from ailbum.layout.assistant import AssistantChoice, LayoutAssistant, render_variants


@dataclass
class R:
    x: float
    y: float
    w: float
    h: float


@dataclass
class FakeCell:
    index: int
    rect: R
    safe: R
    spine_band: R | None = None


@dataclass
class FakeTemplate:
    id: str
    photo_count: int
    cells: list


@dataclass
class FakePlacement:
    cell_index: int
    image_id: int
    crop: R


@dataclass
class FakeDraft:
    template_id: str
    placements: list
    story_ids: tuple = ()
    score: float = 0.0
    warnings: tuple = ()
    alternatives: tuple = ()


@dataclass
class FakeFormat:
    spread_w_mm: float = 426.0
    spread_h_mm: float = 303.0


@pytest.fixture(autouse=True)
def templates(monkeypatch):
    if os.environ.get("SUPERLITE_REAL") == "1":
        return
    cells = [
        FakeCell(0, R(0, 0, 213, 303), R(6, 6, 201, 291)),
        FakeCell(1, R(213, 0, 213, 303), R(213, 6, 201, 291)),
    ]
    fake = types.ModuleType("ailbum.layout.templates")
    fake.format_for = lambda orientation: FakeFormat()
    fake.templates_for = lambda orientation, photo_count=None: [
        FakeTemplate("pages", 2, cells)
    ]
    monkeypatch.setitem(sys.modules, "ailbum.layout.templates", fake)
    try:
        package = importlib.import_module("ailbum.layout")
        monkeypatch.setattr(package, "templates", fake, raising=False)
    except ImportError:
        pass


def draft(*image_ids):
    return FakeDraft(
        "pages", [FakePlacement(i, image_id, R(0, 0, 1, 1)) for i, image_id in enumerate(image_ids)]
    )


def make_jpeg(path, color=(200, 30, 30)):
    Image.new("RGB", (300, 200), color).save(path, "JPEG")
    return str(path)


def test_render_returns_jpeg_within_max_side(tmp_path):
    paths = {1: make_jpeg(tmp_path / "a.jpg"), 2: make_jpeg(tmp_path / "b.jpg")}
    data = render_variants([draft(1, 2), draft(2, 1), draft(1, 2)], paths, "vertical", 500)
    image = Image.open(BytesIO(data))
    assert image.format == "JPEG"
    assert max(image.size) <= 500


def test_missing_photo_renders_placeholder(tmp_path):
    data = render_variants([draft(1, 2)], {1: str(tmp_path / "gone.jpg")}, "vertical", 400)
    assert Image.open(BytesIO(data)).format == "JPEG"


def test_corrupt_photo_renders_placeholder(tmp_path):
    bad = tmp_path / "bad.jpg"
    bad.write_bytes(b"not an image")
    assert render_variants([draft(1, 2)], {1: str(bad)}, "vertical", 400)


def reply_assistant(monkeypatch, content, calls=None):
    def fake(url, payload=None, *, timeout):
        if calls is not None:
            calls.append((url, payload))
        return {"choices": [{"message": {"content": content}}]}

    monkeypatch.setattr(assistant_module, "_request_json", fake)
    return LayoutAssistant("http://x/v1", "m")


def three(tmp_path):
    paths = {1: make_jpeg(tmp_path / "a.jpg"), 2: make_jpeg(tmp_path / "b.jpg")}
    return [draft(1, 2), draft(2, 1), draft(1, 2)], paths


def test_choose_parses_reply(monkeypatch, tmp_path):
    variants, paths = three(tmp_path)
    a = reply_assistant(monkeypatch, '{"choice":"B","reason":"лучше читается"}')
    assert a.choose(variants, paths, "vertical", "Ужин") == AssistantChoice(1, "лучше читается")


def test_reply_with_prose_around_json_parsed(monkeypatch, tmp_path):
    variants, paths = three(tmp_path)
    a = reply_assistant(
        monkeypatch, 'Вот ответ {не json} ```json\n{"choice": "c", "reason": "ок"}\n``` готово'
    )
    assert a.choose(variants, paths, "vertical", "Ужин") == AssistantChoice(2, "ок")


@pytest.mark.parametrize(
    "content",
    [
        '{"choice":"D","reason":"x"}',
        '{"choice":"Z"}',
        '{"choice":1}',
        '{"choice":null}',
        '{"choice":"AB"}',
        '{"choice":""}',
        "[1, 2]",
        "no json",
        "",
        None,
    ],
)
def test_choice_out_of_range_returns_none(monkeypatch, tmp_path, content):
    variants, paths = three(tmp_path)
    a = reply_assistant(monkeypatch, content)
    assert a.choose(variants, paths, "vertical", "Ужин") is None


def test_reason_is_clean_text(monkeypatch, tmp_path):
    variants, paths = three(tmp_path)
    a = reply_assistant(monkeypatch, '{"choice":"A","reason":"' + "я\\n\\u0000" * 300 + '"}')
    choice = a.choose(variants, paths, "vertical", "Ужин")
    assert choice.index == 0
    assert len(choice.reason) <= 200
    assert "\n" not in choice.reason and "\x00" not in choice.reason


def test_non_string_reason_becomes_empty(monkeypatch, tmp_path):
    variants, paths = three(tmp_path)
    a = reply_assistant(monkeypatch, '{"choice":"A","reason":{"x":1}}')
    assert a.choose(variants, paths, "vertical", "Ужин") == AssistantChoice(0, "")


def test_malformed_response_structure_returns_none(monkeypatch, tmp_path):
    variants, paths = three(tmp_path)

    monkeypatch.setattr(assistant_module, "_request_json", lambda *a, **k: {"choices": []})
    assert LayoutAssistant("http://x", "m").choose(variants, paths, "vertical", "t") is None


@pytest.mark.parametrize("error", [TimeoutError("t"), ConnectionError("c"), RuntimeError("r")])
def test_timeout_returns_none(monkeypatch, tmp_path, error):
    variants, paths = three(tmp_path)

    def boom(*a, **k):
        raise error

    monkeypatch.setattr(assistant_module, "_request_json", boom)
    assert LayoutAssistant("http://x", "m").choose(variants, paths, "vertical", "t") is None


def test_single_variant_makes_no_request(monkeypatch, tmp_path):
    calls = []
    a = reply_assistant(monkeypatch, '{"choice":"A"}', calls)
    paths = {1: make_jpeg(tmp_path / "a.jpg")}
    assert a.choose([draft(1, 1)], paths, "vertical", "t") is None
    assert a.choose([], paths, "vertical", "t") is None
    assert calls == []


def test_request_carries_image_and_title(monkeypatch, tmp_path):
    variants, paths = three(tmp_path)
    calls = []
    a = reply_assistant(monkeypatch, '{"choice":"A"}', calls)
    a.choose(variants, paths, "vertical", "Ужин")
    url, payload = calls[0]
    assert url.endswith("/chat/completions")
    parts = payload["messages"][0]["content"]
    assert "Ужин" in parts[0]["text"]
    assert parts[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_connect_false_when_server_down(monkeypatch):
    def down(*a, **k):
        raise ConnectionError("down")

    monkeypatch.setattr(assistant_module, "_request_json", down)
    assert LayoutAssistant("http://x", "m").connect() is False


def test_connect_true_and_picks_model(monkeypatch):
    monkeypatch.setattr(
        assistant_module, "_request_json", lambda *a, **k: {"data": [{"id": "vl-1"}]}
    )
    a = LayoutAssistant("http://x", "")
    assert a.connect() is True
    assert a.model == "vl-1"


def test_connect_false_without_models(monkeypatch):
    monkeypatch.setattr(assistant_module, "_request_json", lambda *a, **k: {"data": []})
    assert LayoutAssistant("http://x", "").connect() is False
