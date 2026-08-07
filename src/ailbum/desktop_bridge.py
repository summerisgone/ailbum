from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path
from typing import Any

from ailbum.database import get_desktop_library, set_desktop_favorite, set_desktop_target


def _dispatch(database: Path, action: str, payload: dict[str, Any]) -> object:
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
