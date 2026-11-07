import hashlib
import subprocess
import sys
from pathlib import Path

from ailbum import albums
from ailbum.database import connect
from ailbum.proxies import build_proxies


def _selection_hash(connection, album_id: int) -> str:
    ids = sorted(
        int(r[0])
        for r in connection.execute("SELECT image_id FROM album_photos WHERE album_id = ?", (album_id,))
    )
    return hashlib.sha256(",".join(str(i) for i in ids).encode()).hexdigest()


def _album_image_ids(connection, album_id: int) -> set[int]:
    run = connection.execute("SELECT run_id FROM albums WHERE id = ?", (album_id,)).fetchone()
    ids = {
        int(r[0])
        for r in connection.execute("SELECT image_id FROM album_photos WHERE album_id = ?", (album_id,))
    }
    if run is not None and run[0]:
        ids |= {
            int(r[0])
            for r in connection.execute(
                "SELECT image_id FROM photo_analysis WHERE run_id = ?", (run[0],)
            )
        }
    return ids


def _needs_export(connection, album_id: int) -> bool:
    if connection.execute("SELECT 1 FROM layouts WHERE album_id = ?", (album_id,)).fetchone() is None:
        return False
    current = _selection_hash(connection, album_id)
    row = connection.execute(
        "SELECT 1 FROM album_exports WHERE album_id = ? AND selection_hash = ?"
        " AND missing_json = '[]' LIMIT 1",
        (album_id, current),
    ).fetchone()
    return row is None


def prepare_archive(database: Path, album_id: int) -> dict:
    with connect(database) as connection:
        album = albums.get_album(connection, album_id)
        if album["status"] == "archived":
            raise ValueError("Альбом уже в архиве")
        if album["status"] == "draft":
            albums.set_status(connection, album_id, "ordered")
        if _needs_export(connection, album_id):
            return {"album_id": album_id, "needs_export": True, "trash": [], "blocked": []}
        ids = _album_image_ids(connection, album_id)
        images = {}
        for image_id in sorted(ids):
            row = connection.execute(
                "SELECT id, path, availability FROM images WHERE id = ?", (image_id,)
            ).fetchone()
            if row is not None and row["availability"] == "present":
                images[image_id] = row
        sha = {
            i: connection.execute("SELECT sha256 FROM images WHERE id = ?", (i,)).fetchone()[0]
            for i in images
        }
        draft_titles: dict[int, str] = {}
        for other in albums.list_albums(connection):
            if other["status"] != "draft":
                continue
            for image_id in _album_image_ids(connection, other["id"]) & set(images):
                draft_titles.setdefault(image_id, other["title"])
    result = build_proxies(database, list(images))
    errors = {f["image_id"]: f["error"] for f in result["failed"]}
    built = set(result["built"])
    trash, blocked = [], []
    proxies_dir = database.parent / "proxies" / "photos"
    for image_id, row in images.items():
        if image_id in draft_titles:
            blocked.append(
                {"image_id": image_id, "reason": f"входит в черновик «{draft_titles[image_id]}»"}
            )
        elif image_id not in built or not (proxies_dir / f"{sha[image_id]}.jpg").is_file():
            error = errors.get(image_id, "превью не найдено")
            blocked.append({"image_id": image_id, "reason": f"не удалось построить превью: {error}"})
        else:
            trash.append(str(row["path"]))
    return {"album_id": album_id, "needs_export": False, "trash": trash, "blocked": blocked}


def complete_archive(database: Path, album_id: int, trashed: list[str]) -> dict:
    with connect(database) as connection:
        albums.get_album(connection, album_id)
        wanted = {str(p) for p in trashed}
        archived_sha: set[str] = set()
        count = 0
        for image_id in _album_image_ids(connection, album_id):
            row = connection.execute(
                "SELECT path, sha256, availability FROM images WHERE id = ?", (image_id,)
            ).fetchone()
            if row is None or row["availability"] != "present":
                continue
            if row["path"] in wanted and not Path(row["path"]).exists():
                connection.execute("UPDATE images SET availability = 'archived' WHERE id = ?", (image_id,))
                archived_sha.add(row["sha256"])
                count += 1
        remaining = sum(
            1
            for image_id in _album_image_ids(connection, album_id)
            if connection.execute(
                "SELECT availability FROM images WHERE id = ?", (image_id,)
            ).fetchone()[0]
            == "present"
        )
        status = albums.get_album(connection, album_id)["status"]
        if remaining == 0 and status == "ordered":
            status = albums.set_status(connection, album_id, "archived")["status"]
        removed = 0
        for sha in archived_sha:
            still = connection.execute(
                "SELECT 1 FROM images WHERE sha256 = ? AND availability = 'present' LIMIT 1", (sha,)
            ).fetchone()
            if still is None:
                for cache in (database.parent / "feature-cache").glob(f"*/{sha}.npz"):
                    cache.unlink()
                    removed += 1
    return {"archived": count, "status": status, "cache_removed": removed}


def _osascript_escape(path: str) -> str:
    return path.replace("\\", "\\\\").replace('"', '\\"')


def trash_paths(paths: list[str]) -> list[str]:
    try:
        from send2trash import send2trash
    except ImportError:
        send2trash = None
    if send2trash is None and sys.platform != "darwin":
        raise RuntimeError("Не найден способ отправить файлы в Корзину")
    done = []
    for path in paths:
        try:
            if send2trash is not None:
                send2trash(path)
            else:
                script = f'tell application "Finder" to delete POSIX file "{_osascript_escape(path)}"'
                subprocess.run(["osascript", "-e", script], check=True, capture_output=True)
        except Exception:  # noqa: BLE001, S112 - a path that fails to trash is skipped
            continue
        done.append(path)
    return done


def confirm_missing(database: Path, image_ids: list[int]) -> int:
    if not image_ids:
        return 0
    marks = ",".join("?" for _ in image_ids)
    with connect(database) as connection:
        cursor = connection.execute(
            f"UPDATE images SET availability = 'archived' WHERE availability = 'missing'"
            f" AND id IN ({marks})",
            [int(i) for i in image_ids],
        )
        return cursor.rowcount
