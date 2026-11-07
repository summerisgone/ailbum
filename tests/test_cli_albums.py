from __future__ import annotations

import sys
import types
from pathlib import Path

import pytest

from ailbum import albums, cli, database


@pytest.fixture
def db(tmp_path: Path) -> Path:
    path = tmp_path / "db.sqlite3"
    with database.connect(path) as c:
        albums.create_album(c, "Турция 2026", ["/p"], target_count=5)
    return path


def run(args, db):
    cli.main([*args, "--database", str(db)])


def status(db, album_id=1):
    with database.connect(db) as c:
        return albums.get_album(c, album_id)["status"]


def test_list_show_order_reopen(db, capsys):
    run(["album", "list"], db)
    out = capsys.readouterr().out
    assert "1\tdraft\tТурция 2026\t0/5" in out
    run(["album", "order", "1"], db)
    assert status(db) == "ordered"
    run(["album", "show", "1"], db)
    assert "Турция 2026" in capsys.readouterr().out
    run(["album", "reopen", "1"], db)
    assert status(db) == "draft"
    run(["album", "list", "--json"], db)
    assert '"Турция 2026"' in capsys.readouterr().out


def test_delete_and_error_exit(db, capsys):
    run(["album", "delete", "1"], db)
    assert "удалён" in capsys.readouterr().out
    with pytest.raises(SystemExit) as exc:
        run(["album", "show", "1"], db)
    assert exc.value.code == 2
    assert "Ошибка: Альбом не найден" in capsys.readouterr().err


def test_archive_needs_export_exits_1(db, capsys, monkeypatch):
    monkeypatch.setattr(
        "ailbum.archive.prepare_archive",
        lambda d, a: {"album_id": a, "needs_export": True, "trash": [],
                      "blocked": [{"image_id": 5, "reason": "входит в черновик «Лето»"}]},
    )
    with pytest.raises(SystemExit) as exc:
        run(["album", "archive", "1"], db)
    assert exc.value.code == 1
    out = capsys.readouterr().out
    assert "Нужен экспорт" in out and "входит в черновик «Лето»" in out


def test_archive_confirmation(db, capsys, monkeypatch):
    calls = []
    monkeypatch.setattr(
        "ailbum.archive.prepare_archive",
        lambda d, a: {"album_id": a, "needs_export": False, "trash": ["/p/ф ото.jpg"], "blocked": []},
    )
    monkeypatch.setattr("ailbum.archive.trash_paths", lambda p: calls.append(p) or p)
    monkeypatch.setattr(
        "ailbum.archive.complete_archive",
        lambda d, a, t: {"archived": len(t), "status": "archived", "cache_removed": 0},
    )
    monkeypatch.setattr("builtins.input", lambda prompt: (calls.append(prompt), "n")[1])
    run(["album", "archive", "1"], db)
    assert "Перенести 1 файлов в Корзину? [y/N]" in calls[0] and len(calls) == 1
    assert "Отменено" in capsys.readouterr().out
    run(["album", "archive", "1", "--yes"], db)
    assert calls[-1] == ["/p/ф ото.jpg"]
    assert '"archived": 1' in capsys.readouterr().out


def test_forget_requires_yes(db, capsys, monkeypatch):
    fake = types.ModuleType("ailbum.forget")
    done = []
    fake.plan_forget = lambda d, a, s: {"album_id": a, "images": 3}
    fake.forget = lambda d, a, s: done.append(a) or {"forgotten": 3}
    monkeypatch.setitem(sys.modules, "ailbum.forget", fake)
    monkeypatch.setattr("ailbum.forget", fake, raising=False)
    run(["forget", "--album", "1"], db)
    assert done == [] and '"images": 3' in capsys.readouterr().out
    run(["forget", "--album", "1", "--yes"], db)
    assert done == [1]


def test_usage_in_mb(db, capsys, monkeypatch):
    fake = types.ModuleType("ailbum.forget")
    fake.usage = lambda d: {"database_bytes": 2 * 1024 * 1024, "proxies_bytes": 0,
                            "feature_cache_bytes": 0, "images": {"present": 2, "missing": 0, "archived": 1}}
    monkeypatch.setitem(sys.modules, "ailbum.forget", fake)
    monkeypatch.setattr("ailbum.forget", fake, raising=False)
    cli.main(["db", "usage", "--database", str(db)])
    out = capsys.readouterr().out
    assert "2.0 МБ" in out and "в архиве 1" in out


def test_ranking_status(db, capsys):
    run(["ranking", "status"], db)
    assert "нужно не меньше 50 пар из 2 альбомов" in capsys.readouterr().out


def test_analyze_attaches_album(db, tmp_path, capsys, monkeypatch):
    source = tmp_path / "new"
    source.mkdir()

    def fake_analyze(src, output, config, recursive, progress, database):
        with __import__("ailbum.database", fromlist=["x"]).connect(database) as c:
            c.execute("INSERT INTO analysis_runs VALUES ('r9','s','o','t','t','classic','{}','{}','completed')")
        return {"run_id": "r9", "summary": {"photos": 0}}

    monkeypatch.setattr(cli, "analyze_library", fake_analyze)
    cli.main(["analyze", str(source), "-o", str(tmp_path / "out"), "--database", str(db), "--quiet"])
    assert "Альбом: 2" in capsys.readouterr().out
