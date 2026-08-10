"""Single entry point for the frozen Electron Python backend."""

from __future__ import annotations

import sys

from ailbum import desktop_bridge, desktop_job


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: ailbum-backend {bridge|job} [arguments]")
    mode = sys.argv.pop(1)
    if mode == "bridge":
        desktop_bridge.main()
    elif mode == "job":
        desktop_job.main()
    else:
        raise SystemExit(f"unknown backend mode: {mode}")


if __name__ == "__main__":
    main()
