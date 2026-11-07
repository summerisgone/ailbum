from __future__ import annotations

import importlib
import os
import sys
import types
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, ClassVar

import pytest
from PIL import Image

from ailbum.database import connect, save_analysis
from ailbum.metadata import collect_image_metadata
from ailbum.models import PhotoRecord, StoryRecord

REAL = os.environ.get("SUPERLITE_REAL") == "1"


@dataclass(slots=True)
class FakeParams:
    orientation: str
    spread_count: int
    min_photos: int
    max_photos: int
    assistant: str = "auto"


@dataclass(slots=True)
class FakeGroup:
    story_ids: tuple[int, ...]
    unit_count: int
    started_at: str | None
    ended_at: str | None


@dataclass(slots=True)
class FakeAllocation:
    story_ids: tuple[int, ...]
    unit_count: int
    spreads: int
    merged: bool


@dataclass(slots=True)
class FakePhoto:
    image_id: int
    unit_key: str
    story_id: int | None
    selected: bool = True


@dataclass(slots=True)
class FakePlacement:
    image_id: int


@dataclass(slots=True)
class FakeSpread:
    template_id: str
    placements: list[FakePlacement]
    story_ids: tuple[int, ...] = ()
    warnings: tuple[str, ...] = ()
    alternatives: tuple[FakeSpread, ...] = ()
    assistant_reason: str | None = None


@dataclass(slots=True)
class FakeComposed:
    spreads: list[FakeSpread]
    unplaced: list[dict[str, Any]] = field(default_factory=list)


@dataclass(slots=True)
class FakeChoice:
    index: int
    reason: str


def _stub(name: str, **attrs: Any) -> None:
    try:
        importlib.import_module(name)
    except ImportError:
        module = types.ModuleType(name)
        module.__dict__.update(attrs)
        sys.modules[name] = module


def _noop(*args: Any, **kwargs: Any) -> Any:
    raise NotImplementedError


if not REAL:
    _stub("ailbum.layout.types", LayoutParams=FakeParams)
    _stub("ailbum.layout.allocation", StoryGroup=FakeGroup, allocate_spreads=_noop)
    _stub("ailbum.layout.assistant", LayoutAssistant=object)
    _stub("ailbum.layout.composer", best_variants=_noop, compose_group=_noop)
    _stub("ailbum.layout.facts", load_pool=_noop)
    _stub(
        "ailbum.layout.store", save_layout=_noop, load_layout=_noop, selection_hash=_noop
    )

from ailbum.layout import service
from ailbum.layout.types import LayoutParams


class FakeAssistant:
    connected = True
    choice: FakeChoice | None = FakeChoice(1, "лучше")
    raises = False
    instances: ClassVar[list[FakeAssistant]] = []

    def __init__(self, base_url: str, model: str, timeout: float = 90.0) -> None:
        self.base_url = base_url
        self.model = model
        self.connect_calls = 0
        self.choose_calls = 0
        self.titles: list[str] = []
        FakeAssistant.instances.append(self)

    def connect(self) -> bool:
        self.connect_calls += 1
        return self.connected

    def choose(self, variants, paths, orientation, story_title, wish=""):
        self.choose_calls += 1
        self.titles.append(story_title)
        if self.raises:
            raise RuntimeError("down")
        return self.choice


class Env:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.db = root / "a.sqlite"
        self.pool: list[FakePhoto] = []
        self.load_pool_args: list[Any] = []
        self.saved: dict[str, Any] = {}
        self.composed: list[FakeComposed] = []
        self.alts: list[FakeSpread] = []
        self.seen: list[list[int]] = []


TITLES = {1: "Ужин", 2: "Прогулка"}


def _seed(e: Env, per_story: dict[int | None, int]) -> None:
    source = e.root / "photos"
    source.mkdir(exist_ok=True)
    records, metadata = [], []
    for story, count in per_story.items():
        for _ in range(count):
            n = len(records) + 1
            size = (300, 200) if n % 2 else (200, 300)
            path = source / f"{n}.jpg"
            Image.new("RGB", size, (n * 5 % 255, 80, 120)).save(path)
            day = story or 9
            records.append(
                PhotoRecord(
                    f"p{n}", str(path.resolve()), size[0], size[1],
                    f"2024-01-0{day}T10:{n:02d}:00", 100.0, 1.0, 0.8, False,
                    story_id=story, selected=True,
                )
            )
            metadata.append(collect_image_metadata(path, source))
    stories = [
        StoryRecord(
            sid, TITLES[sid],
            [r.photo_id for r in records if r.story_id == sid],
            f"2024-01-0{sid}T10:00:00", f"2024-01-0{sid}T11:00:00",
            next(r.photo_id for r in records if r.story_id == sid),
        )
        for sid in per_story
        if sid is not None
    ]
    manifest = {
        "run_id": "r", "started_at": "t", "generated_at": "t", "face_backend": "x",
        "config": {"lmstudio_url": "http://x/v1", "lmstudio_model": "m1"}, "summary": {},
    }
    save_analysis(e.db, source, e.root / "o", manifest, records, [], metadata, 0.8, stories)
    with connect(e.db) as c:
        for i, r in enumerate(records, 1):
            c.execute(
                "INSERT INTO photo_selections VALUES ('r', ?, 't', ?)", (i, i)
            )
    e.pool = [
        FakePhoto(i, f"image:{i}", r.story_id) for i, r in enumerate(records, 1)
    ]


fake_only = pytest.mark.skipif(REAL, reason="uses fakes for producers")


@pytest.fixture
def env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Env:
    e = Env(tmp_path)
    if REAL:
        return e

    def fake_load_pool(connection, run_id, detector, progress=None):
        e.load_pool_args.append(detector)
        if progress:
            progress(1, 1)
        return e.pool

    def fake_allocate(groups, spread_count, min_photos, max_photos):
        return [
            FakeAllocation(
                g.story_ids, g.unit_count, 1 if i else spread_count - len(groups) + 1, False
            )
            for i, g in enumerate(groups)
        ]

    def fake_compose(photos, allocation, params):
        e.seen.append([p.image_id for p in photos])
        placements = [FakePlacement(p.image_id) for p in photos[:3]]
        alt = FakeSpread(
            "alt", placements, allocation.story_ids, ("replaced",), (), None
        )
        e.alts.append(alt)
        composed = FakeComposed(
            [FakeSpread("page_2h", placements, allocation.story_ids, (), (alt,))],
            [{"image_id": 99, "reason": "capacity"}],
        )
        e.composed.append(composed)
        return composed

    def fake_save(connection, run_id, params, spreads, unplaced, warnings, sel, model):
        e.saved = {
            "spreads": list(spreads),
            "unplaced": unplaced,
            "warnings": warnings,
            "model": model,
        }
        return 1

    FakeAssistant.instances = []
    FakeAssistant.connected = True
    FakeAssistant.choice = FakeChoice(1, "лучше")
    FakeAssistant.raises = False
    monkeypatch.setattr(service, "load_pool", fake_load_pool)
    monkeypatch.setattr(service, "allocate_spreads", fake_allocate)
    monkeypatch.setattr(service, "compose_group", fake_compose)
    monkeypatch.setattr(service, "save_layout", fake_save)
    monkeypatch.setattr(service, "selection_hash", lambda c, r: "h")
    monkeypatch.setattr(service, "load_layout", lambda c, r: {"spreads": e.saved["spreads"]})
    monkeypatch.setattr(service, "LayoutAssistant", FakeAssistant)
    monkeypatch.setattr(service, "StoryGroup", FakeGroup)
    return e


def _pool(e: Env, per_story: dict[int | None, int]) -> None:
    _seed(e, per_story)


def test_preflight_counts_units_not_photos(env: Env) -> None:
    _pool(env, {1: 3, 2: 1})
    if not REAL:
        env.pool = [
            FakePhoto(1, "cluster:3", 1),
            FakePhoto(2, "cluster:3", 1, selected=False),
            FakePhoto(3, "cluster:3", 1, selected=False),
            FakePhoto(4, "image:4", 2),
        ]
    result = service.preflight(env.db, "r", LayoutParams("vertical", 2, 1, 6))
    assert result["pool_count"] == 4
    if REAL:
        assert result["unit_count"] == 4
    else:
        assert result["unit_count"] == 2
    assert result["story_count"] == 2


def test_min_max_needed(env: Env) -> None:
    _pool(env, {1: 20, 2: 20})
    result = service.preflight(env.db, "r", LayoutParams("vertical", 10, 3, 6))
    assert result["min_needed"] == 30
    assert result["max_used"] == 60
    assert result["errors"] == []
    assert [a["title"] for a in result["allocation"]] == ["Ужин", "Прогулка"]


def test_preflight_zero_spreads_error(env: Env) -> None:
    _pool(env, {1: 5})
    result = service.preflight(env.db, "r", LayoutParams("vertical", 0, 3, 6))
    assert result["errors"] == ["Число разворотов должно быть не меньше 1"]
    assert result["allocation"] == []


def test_preflight_range_errors(env: Env) -> None:
    _pool(env, {1: 5})
    result = service.preflight(env.db, "r", LayoutParams("vertical", 1, 5, 3))
    assert any("больше максимума" in e for e in result["errors"])
    result = service.preflight(env.db, "r", LayoutParams("vertical", 1, 0, 7))
    assert any("от 1 до 6" in e for e in result["errors"])


def test_preflight_fewer_units_than_spreads(env: Env) -> None:
    _pool(env, {1: 2})
    result = service.preflight(env.db, "r", LayoutParams("vertical", 5, 1, 6))
    assert result["errors"] == ["Кадров меньше, чем разворотов"]


def test_preflight_skips_detector(env: Env) -> None:
    _pool(env, {1: 5})
    service.preflight(env.db, "r", LayoutParams("vertical", 1, 3, 6))
    if not REAL:
        assert env.load_pool_args == [None]


def test_generate_invalid_params_raises(env: Env) -> None:
    _pool(env, {1: 5})
    with pytest.raises(ValueError, match="Число разворотов должно быть не меньше 1"):
        service.generate(env.db, "r", LayoutParams("vertical", 0, 3, 6), None)
    assert env.saved == {}


def test_generate_empty_selection_raises(env: Env) -> None:
    _pool(env, {})
    with pytest.raises(ValueError):
        service.generate(env.db, "r", LayoutParams("vertical", 2, 3, 6), None)


@fake_only
def test_generate_spread_count_exact(env: Env) -> None:
    _pool(env, {1: 12, 2: 8})
    events: list[tuple] = []
    service.generate(
        env.db,
        "r",
        LayoutParams("vertical", 5, 3, 6, "off"),
        None,
        lambda *a: events.append(a),
    )
    assert len(env.saved["spreads"]) == len(env.composed)
    assert env.saved["unplaced"] == [{"image_id": 99, "reason": "capacity"}] * 2
    assert {e[0] for e in events} >= {"Анализ объектов", "Компоновка"}


def test_generate_real_spread_count_exact(env: Env) -> None:
    if not REAL:
        pytest.skip("real producers only")
    _pool(env, {1: 12, 2: 8})
    layout = service.generate(env.db, "r", LayoutParams("vertical", 5, 3, 6, "off"), None)
    assert len(layout["spreads"]) == 5


@fake_only
def test_assistant_off_never_connects(env: Env) -> None:
    _pool(env, {1: 6})
    service.generate(env.db, "r", LayoutParams("vertical", 1, 3, 6, "off"), None)
    assert FakeAssistant.instances == []
    assert env.saved["model"] is None
    assert service.ASSISTANT_WARNING not in env.saved["warnings"]


@fake_only
def test_assistant_uses_run_config_and_choice(env: Env) -> None:
    _pool(env, {1: 6, 2: 6})
    service.generate(env.db, "r", LayoutParams("vertical", 2, 3, 6, "auto"), None)
    bot = FakeAssistant.instances[0]
    assert (bot.base_url, bot.model) == ("http://x/v1", "m1")
    assert env.saved["model"] == "m1"
    assert bot.titles == ["Ужин", "Прогулка"]


@fake_only
def test_assistant_choice_keeps_replacement_and_reason(env: Env) -> None:
    _pool(env, {1: 6})
    service.generate(env.db, "r", LayoutParams("vertical", 1, 3, 6, "auto"), None)
    saved = env.saved["spreads"][0]
    alt = env.alts[0]
    assert saved.template_id == "alt"
    assert saved.warnings == ("replaced",)
    assert saved.story_ids == alt.story_ids == (1,)
    assert saved.assistant_reason == "лучше"


@fake_only
def test_assistant_failure_keeps_engine_choice(env: Env) -> None:
    _pool(env, {1: 6})
    FakeAssistant.raises = True
    service.generate(env.db, "r", LayoutParams("vertical", 1, 3, 6, "auto"), None)
    assert env.saved["spreads"][0] is env.composed[0].spreads[0]
    FakeAssistant.raises = False
    FakeAssistant.choice = FakeChoice(7, "x")
    service.generate(env.db, "r", LayoutParams("vertical", 1, 3, 6, "auto"), None)
    assert env.saved["spreads"][0] is env.composed[1].spreads[0]


@fake_only
def test_assistant_server_down_warns(env: Env) -> None:
    _pool(env, {1: 6})
    FakeAssistant.connected = False
    service.generate(env.db, "r", LayoutParams("vertical", 1, 3, 6, "auto"), None)
    assert service.ASSISTANT_WARNING in env.saved["warnings"]
    assert env.saved["model"] is None
    assert FakeAssistant.instances[0].choose_calls == 0


def test_no_detector_model_warns(env: Env) -> None:
    _pool(env, {1: 6})
    layout = service.generate(env.db, "r", LayoutParams("vertical", 1, 3, 6, "off"), None)
    if REAL:
        assert service.DETECTOR_WARNING in layout["warnings"]
    else:
        assert service.DETECTOR_WARNING in env.saved["warnings"]
        assert env.load_pool_args == [None]


@fake_only
def test_untimed_group_photos_not_lost(env: Env) -> None:
    _pool(env, {1: 4, None: 2})
    service.generate(env.db, "r", LayoutParams("vertical", 2, 1, 6, "off"), None)
    assert sorted(i for ids in env.seen for i in ids) == [1, 2, 3, 4, 5, 6]
