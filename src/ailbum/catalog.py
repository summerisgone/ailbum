from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from ailbum.database import index_metadata
from ailbum.io import discover_images, relative_paths
from ailbum.metadata import collect_image_metadata

Progress = Callable[[str], None]


def index_library(
    source: Path,
    database: Path,
    recursive: bool = True,
    progress: Progress | None = None,
) -> dict[str, int]:
    emit = progress or (lambda _: None)
    paths = discover_images(source, recursive=recursive)
    if not paths:
        raise ValueError(f"No supported images found in {source}")
    display_paths = relative_paths(paths, source)
    metadata = []
    for index, path in enumerate(paths, start=1):
        emit(f"[{index}/{len(paths)}] {display_paths[path]}")
        metadata.append(collect_image_metadata(path, source))
    return index_metadata(database, source, metadata)
