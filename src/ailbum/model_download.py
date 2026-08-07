from __future__ import annotations

import hashlib
import shutil
import ssl
import urllib.request
from pathlib import Path

import certifi

from ailbum.cv.faces import (
    EXPRESSION_FILENAME,
    EYE_STATE_FILENAME,
    SFACE_FILENAME,
    YUNET_FILENAME,
)

MODEL_SOURCES = {
    YUNET_FILENAME: (
        (
            "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/"
            "face_detection_yunet_2023mar.onnx"
        ),
        "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
    ),
    SFACE_FILENAME: (
        (
            "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/"
            "face_recognition_sface_2021dec.onnx"
        ),
        "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
    ),
    EYE_STATE_FILENAME: (
        (
            "https://storage.openvinotoolkit.org/repositories/open_model_zoo/public/"
            "2022.1/open-closed-eye-0001/open_closed_eye.onnx"
        ),
        "4daa100034482525a26c9afb9297c16580a531189e66e3d2b2ac7d32becfd593",
    ),
    EXPRESSION_FILENAME: (
        (
            "https://github.com/opencv/opencv_zoo/raw/main/models/"
            "facial_expression_recognition/"
            "facial_expression_recognition_mobilefacenet_2022july.onnx"
        ),
        "4f61307602fc089ce20488a31d4e4614e3c9753a7d6c41578c854858b183e1a9",
    ),
}


def download_models(destination: Path) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    downloaded: list[Path] = []
    tls_context = ssl.create_default_context(cafile=certifi.where())
    for filename, (url, expected_hash) in MODEL_SOURCES.items():
        target = destination / filename
        if target.exists() and target.stat().st_size > 0:
            if _sha256(target) != expected_hash:
                raise RuntimeError(
                    f"Existing model failed SHA-256 validation: {target}. "
                    "Move it aside and retry."
                )
            downloaded.append(target)
            continue
        temporary = target.with_suffix(target.suffix + ".part")
        try:
            with (
                urllib.request.urlopen(url, timeout=120, context=tls_context) as response,
                temporary.open("wb") as output,
            ):
                shutil.copyfileobj(response, output)
            actual_hash = _sha256(temporary)
            if actual_hash != expected_hash:
                raise RuntimeError(
                    f"Downloaded model failed SHA-256 validation: {filename} "
                    f"(expected {expected_hash}, got {actual_hash})"
                )
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
        downloaded.append(target)
    return downloaded


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
