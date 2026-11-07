from __future__ import annotations

import argparse
import base64
import json
import sys
import traceback
from pathlib import Path
from typing import Any

from ailbum import album_library, albums, archive, proxies
from ailbum.database import (
    connect,
    create_person_from_face,
    database_summary,
    get_desktop_faces,
    get_desktop_people,
    merge_people,
    name_person,
    set_face_person,
)
from ailbum.layout import editing, service, store
from ailbum.layout.export import export_originals
from ailbum.layout.preferences import MAX_PROMPT
from ailbum.layout.templates import format_for, templates_for
from ailbum.layout.types import LayoutParams


def _library(database: Path, album_id: int | None) -> dict[str, Any]:
    library = album_library.get_library(database, album_id)
    photos = library["photos"]
    with connect(database) as connection:
        hashes = {
            int(r["id"]): r["sha256"]
            for r in connection.execute("SELECT id, sha256 FROM images")
        }
    for photo in photos:
        source = proxies.image_source(
            database,
            {
                "path": photo["path"],
                "sha256": hashes.get(int(photo["id"])),
                "availability": photo["availability"],
            },
        )
        photo["media_path"] = str(source) if source is not None else None
    return library


def _layout_params(payload: dict[str, Any]) -> LayoutParams:
    return LayoutParams(
        str(payload["orientation"]),
        int(payload["spread_count"]),
        int(payload["min_photos"]),
        int(payload["max_photos"]),
        str(payload.get("assistant", "auto")),
        str(payload.get("prompt") or "")[:MAX_PROMPT],
    )


def _layout_templates(orientation: str, photo_count: int | None) -> list[dict[str, Any]]:
    fmt = format_for(orientation)
    return [
        {
            "id": template.id,
            "photo_count": template.photo_count,
            "cells": [
                {
                    "index": cell.index,
                    "x": cell.rect.x / fmt.spread_w_mm,
                    "y": cell.rect.y / fmt.spread_h_mm,
                    "w": cell.rect.w / fmt.spread_w_mm,
                    "h": cell.rect.h / fmt.spread_h_mm,
                }
                for cell in template.cells
            ],
        }
        for template in templates_for(orientation, photo_count)
    ]


def _dispatch_layout(database: Path, action: str, payload: dict[str, Any]) -> object:
    if action == "layout.preflight":
        return service.preflight(database, int(payload["album_id"]), _layout_params(payload))
    if action == "layout.get":
        with connect(database) as connection:
            return store.load_layout(connection, int(payload["album_id"]))
    if action == "layout.templates":
        count = payload.get("photo_count")
        return _layout_templates(
            str(payload["orientation"]), int(count) if count is not None else None
        )
    if action == "layout.export":
        return export_originals(database, int(payload["album_id"]), Path(str(payload["folder"])))
    if action == "layout.parse_prompt":
        return editing.parse_prompt(str(payload.get("prompt") or ""))
    spread_id = int(payload["spread_id"])
    if action == "layout.similar":
        return editing.similar(database, spread_id, int(payload["cell_index"]))
    if action == "layout.variants":
        return editing.variants(database, spread_id)
    if action == "layout.apply_variant":
        return editing.apply_variant(
            database,
            spread_id,
            str(payload["template_id"]),
            [int(i) for i in payload["image_ids"]],
        )
    if action == "layout.alternatives":
        return editing.alternatives(database, spread_id, int(payload["cell_index"]))
    if action == "layout.set_photo":
        return editing.set_photo(
            database, spread_id, int(payload["cell_index"]), int(payload["image_id"])
        )
    if action == "layout.swap_cells":
        return editing.swap_cells(
            database, spread_id, int(payload["cell_a"]), int(payload["cell_b"])
        )
    if action == "layout.set_template":
        return editing.set_template(database, spread_id, str(payload["template_id"]))
    if action == "layout.set_crop":
        return editing.set_crop(
            database, spread_id, int(payload["cell_index"]), dict(payload["crop"])
        )
    if action == "layout.recompose_spread":
        return editing.recompose_spread(
            database, spread_id, str(payload.get("prompt") or "")[:MAX_PROMPT]
        )
    raise ValueError(f"Unknown desktop action: {action}")


def _dispatch(database: Path, action: str, payload: dict[str, Any]) -> object:
    if action == "database.initialize":
        with connect(database):
            pass
        return database_summary(database)
    if action == "database.summary":
        return database_summary(database)
    if action == "library.bootstrap":
        value = payload.get("album_id")
        return _library(database, int(value) if value is not None else None)
    if action == "favorite.set":
        with connect(database) as connection:
            return album_library.set_photo(
                connection,
                int(payload["album_id"]),
                int(payload["image_id"]),
                bool(payload["favorite"]),
            )
    if action == "target.set":
        with connect(database) as connection:
            return album_library.set_target(
                connection, int(payload["album_id"]), int(payload["target_count"])
            )
    if action == "selection.autofill":
        with connect(database) as connection:
            return album_library.autofill(connection, int(payload["album_id"]))
    if action == "album.list":
        with connect(database) as connection:
            return albums.list_albums(connection)
    if action == "album.status":
        with connect(database) as connection:
            return albums.set_status(
                connection, int(payload["album_id"]), str(payload["status"])
            )
    if action == "album.rename":
        with connect(database) as connection:
            return albums.rename_album(
                connection, int(payload["album_id"]), str(payload["title"])
            )
    if action == "album.delete":
        with connect(database) as connection:
            albums.delete_album(
                connection, int(payload["album_id"]), bool(payload.get("forget_decisions"))
            )
        return {"deleted": True}
    if action == "album.prepare_archive":
        return archive.prepare_archive(database, int(payload["album_id"]))
    if action == "album.complete_archive":
        return archive.complete_archive(
            database, int(payload["album_id"]), [str(p) for p in payload["trashed"]]
        )
    if action == "album.confirm_missing":
        return {"confirmed": archive.confirm_missing(
            database, [int(i) for i in payload["image_ids"]]
        )}
    if action == "album.usage":
        from ailbum import forget

        return forget.usage(database)
    if action == "people.bootstrap":
        return get_desktop_people(database)
    if action == "person.faces":
        value = payload.get("person_id")
        return get_desktop_faces(database, int(value) if value is not None else None)
    if action == "person.name":
        return name_person(database, int(payload["person_id"]), payload.get("name"))
    if action == "person.merge":
        return merge_people(database, int(payload["target_id"]), [int(payload["source_id"])])
    if action == "face.assign":
        value = payload.get("person_id")
        return set_face_person(
            database,
            int(payload["face_id"]),
            int(value) if value is not None else None,
        )
    if action == "face.create_person":
        return create_person_from_face(
            database, int(payload["face_id"]), payload.get("name")
        )
    if action == "face.thumbnail":
        data = proxies.face_thumbnail(database, int(payload["face_id"]))
        if data is None:
            return None
        return {"mime_type": "image/jpeg", "base64": base64.b64encode(data).decode()}
    if action.startswith("layout."):
        return _dispatch_layout(database, action, payload)
    if action == "ping":
        return {"ok": True}
    raise ValueError(f"Unknown desktop action: {action}")


def serve(database: Path) -> None:
    for raw_line in sys.stdin:
        request: object = None
        try:
            request = json.loads(raw_line)
            if not isinstance(request, dict):
                raise TypeError("Desktop request must be a JSON object")
            request_id = request["id"]
            result = _dispatch(database, str(request["action"]), request.get("payload") or {})
            response = {"id": request_id, "result": result}
        # A malformed RPC must not terminate the long-running bridge.
        except Exception as error:  # noqa: BLE001
            response = {
                "id": request.get("id") if isinstance(request, dict) else None,
                "error": str(error),
            }
            traceback.print_exc(file=sys.stderr)
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Ailbum Electron JSON-lines bridge")
    parser.add_argument("--database", type=Path, required=True)
    args = parser.parse_args()
    serve(args.database)


if __name__ == "__main__":
    main()
