from __future__ import annotations

import json
from pathlib import Path

import pytest

from ailbum import desktop_bridge, desktop_job
from ailbum.layout import editing, service
from ailbum.layout.types import LayoutParams

PARAMS = {
    "run_id": "r",
    "orientation": "vertical",
    "spread_count": 4,
    "min_photos": 3,
    "max_photos": 5,
    "assistant": "off",
}


@pytest.fixture
def fakes(monkeypatch):
    calls: list[tuple] = []
    if __import__("os").environ.get("SUPERLITE_REAL") == "1":
        return calls

    def record(name, result):
        def fake(*args):
            calls.append((name, *args))
            return result

        return fake

    monkeypatch.setattr(service, "preflight", record("preflight", {"errors": []}))
    for name in ("set_photo", "swap_cells", "set_template", "set_crop", "recompose_spread"):
        monkeypatch.setattr(editing, name, record(name, {"id": 1}), raising=False)
    monkeypatch.setattr(editing, "alternatives", record("alternatives", [{"image_id": 2}]), raising=False)
    return calls


def test_bridge_routes_all_layout_actions(fakes, tmp_path: Path):
    if __import__("os").environ.get("SUPERLITE_REAL") == "1":
        pytest.skip("routing uses fakes")
    db = tmp_path / "a.db"
    d = desktop_bridge._dispatch
    assert d(db, "layout.preflight", dict(PARAMS)) == {"errors": []}
    assert d(db, "layout.alternatives", {"spread_id": "5", "cell_index": 1}) == [{"image_id": 2}]
    d(db, "layout.set_photo", {"spread_id": 5, "cell_index": 0, "image_id": 7})
    d(db, "layout.swap_cells", {"spread_id": 5, "cell_a": 0, "cell_b": 1})
    d(db, "layout.set_template", {"spread_id": 5, "template_id": "page_2h"})
    crop = {"x": 0.1, "y": 0, "w": 0.5, "h": 1}
    d(db, "layout.set_crop", {"spread_id": 5, "cell_index": 0, "crop": crop})
    d(db, "layout.recompose_spread", {"spread_id": 5})
    assert [c[0] for c in fakes] == [
        "preflight", "alternatives", "set_photo", "swap_cells",
        "set_template", "set_crop", "recompose_spread",
    ]
    assert fakes[2][1:] == (db, 5, 0, 7)
    assert fakes[5][1:] == (db, 5, 0, crop)


def test_dispatch_preflight_builds_params(fakes, tmp_path: Path):
    if __import__("os").environ.get("SUPERLITE_REAL") == "1":
        pytest.skip("uses fakes")
    desktop_bridge._dispatch(tmp_path / "a.db", "layout.preflight", dict(PARAMS))
    _, _db, run_id, params = fakes[0]
    assert run_id == "r"
    assert params == LayoutParams("vertical", 4, 3, 5, "off")


def test_dispatch_layout_get_null(tmp_path: Path):
    db = tmp_path / "a.db"
    desktop_bridge._dispatch(db, "database.initialize", {})
    assert desktop_bridge._dispatch(db, "layout.get", {"run_id": "nope"}) is None


def test_dispatch_templates():
    result = desktop_bridge._dispatch(Path("x.db"), "layout.templates",
                                      {"orientation": "vertical", "photo_count": 3})
    assert {t["id"] for t in result} == {"page_2h", "page_2h_m", "row_3", "pano_2"}
    cell = result[0]["cells"][0]
    assert set(cell) == {"index", "x", "y", "w", "h"}
    assert 0 <= cell["x"] <= 1 and 0 < cell["w"] <= 1
    assert result[0]["photo_count"] == 3


def test_job_parser_accepts_layout_kind():
    args = desktop_job.build_parser().parse_args(
        ["layout", "--database", "a.db", "--run-id", "r", "--params", "{}"]
    )
    assert args.kind == "layout" and args.run_id == "r" and args.params == "{}"


def test_invalid_params_json_emits_error_event(capsys):
    with pytest.raises(SystemExit) as exit_info:
        desktop_job.main(["layout", "--database", "a.db", "--run-id", "r", "--params", "{bad"])
    assert exit_info.value.code == 2
    event = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert event["type"] == "error"


def test_layout_job_runs_generate_and_reports_progress(monkeypatch, capsys):
    seen = {}

    def fake_generate(database, run_id, params, models_dir, progress=None):
        seen["args"] = (run_id, params, models_dir)
        progress("Компоновка", "x", 1, 2)
        return {"id": 3}

    monkeypatch.setattr(service, "generate", fake_generate)
    desktop_job.main(
        ["layout", "--database", "a.db", "--run-id", "r", "--models-dir", "m",
         "--params", json.dumps({k: v for k, v in PARAMS.items() if k != "run_id"})]
    )
    lines = [json.loads(x) for x in capsys.readouterr().out.strip().splitlines()]
    assert lines[0] == {"type": "progress", "stage": "Компоновка", "detail": "x",
                        "current": 1, "total": 2}
    assert lines[-1] == {"type": "complete", "result": {"id": 3}}
    assert seen["args"] == ("r", LayoutParams("vertical", 4, 3, 5, "off"), Path("m"))
