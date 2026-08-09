from __future__ import annotations

import argparse
import base64
import json
import sys
import traceback
from io import BytesIO
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps

from ailbum.database import (
    connect,
    create_person_from_face,
    database_summary,
    get_desktop_faces,
    get_desktop_library,
    get_desktop_people,
    name_person,
    set_desktop_favorite,
    set_desktop_target,
    set_face_person,
)


def _face_thumbnail(database: Path, face_id: int, size: int = 240) -> dict[str, str]:
    with connect(database) as connection:
        face = connection.execute(
            """
            SELECT f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height, i.path
            FROM faces AS f JOIN images AS i ON i.id = f.image_id
            WHERE f.id = ?
            """,
            (face_id,),
        ).fetchone()
    if face is None:
        raise ValueError(f"Face id does not exist: {face_id}")
    with Image.open(Path(str(face["path"]))) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")
        width = int(face["bbox_width"])
        height = int(face["bbox_height"])
        margin = round(max(width, height) * 0.2)
        x = int(face["bbox_x"])
        y = int(face["bbox_y"])
        crop = image.crop(
            (
                max(0, x - margin),
                max(0, y - margin),
                min(image.width, x + width + margin),
                min(image.height, y + height + margin),
            )
        )
        tile = ImageOps.fit(crop, (size, size), method=Image.Resampling.LANCZOS)
        output = BytesIO()
        tile.save(output, format="JPEG", quality=86, optimize=True)
    return {"mime_type": "image/jpeg", "base64": base64.b64encode(output.getvalue()).decode()}


def _dispatch(database: Path, action: str, payload: dict[str, Any]) -> object:
    if action == "database.initialize":
        with connect(database):
            pass
        return database_summary(database)
    if action == "database.summary":
        return database_summary(database)
    if action == "library.bootstrap":
        return get_desktop_library(database, payload.get("run_id"))
    if action == "favorite.set":
        return set_desktop_favorite(
            database,
            str(payload["run_id"]),
            int(payload["image_id"]),
            bool(payload["favorite"]),
        )
    if action == "target.set":
        return set_desktop_target(
            database, str(payload["run_id"]), int(payload["target_count"])
        )
    if action == "people.bootstrap":
        return get_desktop_people(database)
    if action == "person.faces":
        value = payload.get("person_id")
        return get_desktop_faces(database, int(value) if value is not None else None)
    if action == "person.name":
        return name_person(database, int(payload["person_id"]), payload.get("name"))
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
        return _face_thumbnail(database, int(payload["face_id"]))
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
