"""Offline converter: ONNX / CLIP -> CoreML (.mlpackage) + clip_text.json in swift/Models.

Run from the repo root:  PYTHONPATH=src python swift/Tools/convert_models.py [--force] [--check]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "swift" / "Models"
SRC = Path(os.environ.get("AILBUM_ONNX_DIR", "/Users/ivan/projects/ailbum/models"))
CLIP_ID = "openai/clip-vit-base-patch32"
YOLOX_URL = (
    "https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/"
    "object_detection_yolox_2022nov.onnx"
)
YOLOX_SHA = "c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063"

# name -> (onnx file, input shape)
ONNX_MODELS = {
    "yunet": ("face_detection_yunet_2023mar.onnx", (1, 3, 640, 640)),
    "sface": ("face_recognition_sface_2021dec.onnx", (1, 3, 112, 112)),
    "eye": ("open_closed_eye.onnx", (1, 3, 32, 32)),
    "expression": ("facial_expression_recognition_mobilefacenet_2022july.onnx", (1, 3, 112, 112)),
    "yolox": ("object_detection_yolox_2022nov.onnx", (1, 3, 640, 640)),
}
ALL = [*ONNX_MODELS, "clip_vision", "clip_text"]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ensure_yolox() -> Path:
    path = SRC / ONNX_MODELS["yolox"][0]
    if not path.exists():
        SRC.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(YOLOX_URL, path)
    if sha256(path) != YOLOX_SHA:
        raise SystemExit(f"sha256 mismatch for {path}")
    return path


def onnx_io(path: Path) -> tuple[str, list[str]]:
    import onnx

    graph = onnx.load(str(path)).graph
    init = {i.name for i in graph.initializer}
    inputs = [i.name for i in graph.input if i.name not in init]
    return inputs[0], [o.name for o in graph.output]


def convert_traced(module, shape, in_name, out_names, dest: Path) -> None:
    import coremltools as ct
    import torch

    module.eval()
    example = torch.zeros(*shape)
    with torch.no_grad():
        traced = torch.jit.trace(module, example, strict=False)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name=in_name, shape=shape, dtype=np.float32)],
        outputs=[ct.TensorType(name=n) for n in out_names],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    # ML Program names must match [a-zA-Z_][a-zA-Z0-9_]*: eye becomes input_1 / var_19
    model.save(str(dest))


def convert_onnx(name: str) -> None:
    import onnx2torch

    fname, shape = ONNX_MODELS[name]
    path = ensure_yolox() if name == "yolox" else SRC / fname
    in_name, out_names = onnx_io(path)
    module = onnx2torch.convert(str(path))
    convert_traced(module, shape, in_name, out_names, OUT / f"{name}.mlpackage")


def load_clip():
    from transformers import CLIPModel

    return CLIPModel.from_pretrained(CLIP_ID).eval()


def clip_vision_module(model):
    import torch

    class Vision(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.m = model

        def forward(self, pixel_values):
            feats = self.m.get_image_features(pixel_values=pixel_values)
            return feats if isinstance(feats, torch.Tensor) else feats.pooler_output

    return Vision()


def convert_clip_vision() -> None:
    convert_traced(clip_vision_module(load_clip()), (1, 3, 224, 224), "pixel_values",
                   ["image_embeds"], OUT / "clip_vision.mlpackage")


def write_clip_text() -> None:
    import torch
    from transformers import CLIPTokenizer

    from ailbum.cv.semantics import AESTHETIC_PROMPTS, OBJECT_PROMPTS, SCENE_PROMPTS

    model = load_clip()
    tok = CLIPTokenizer.from_pretrained(CLIP_ID)

    def embed(prompts):
        batch = tok(list(prompts), padding=True, return_tensors="pt")
        with torch.no_grad():
            feats = model.get_text_features(**batch)
        if not isinstance(feats, torch.Tensor):
            feats = feats.pooler_output
        feats = feats / feats.norm(dim=-1, keepdim=True).clamp_min(1e-12)
        return feats.double().numpy().tolist()

    aesthetic = embed(AESTHETIC_PROMPTS)
    scenes = embed(SCENE_PROMPTS.values())
    objects = embed(OBJECT_PROMPTS.values())
    data = {
        "model": CLIP_ID,
        "logit_scale": float(model.logit_scale.exp().item()),
        "aesthetic": aesthetic,
        "scenes": [{"key": k, "embedding": e} for k, e in zip(SCENE_PROMPTS, scenes, strict=True)],
        "objects": [{"key": k, "embedding": e} for k, e in zip(OBJECT_PROMPTS, objects, strict=True)],
    }
    (OUT / "clip_text.json").write_text(json.dumps(data))


def output_path(name: str) -> Path:
    return OUT / ("clip_text.json" if name == "clip_text" else f"{name}.mlpackage")


def build(force: bool) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ALL:
        dest = output_path(name)
        if dest.exists() and not force:
            print(f"skip {name} (exists)")
            continue
        print(f"convert {name}")
        if name in ONNX_MODELS:
            convert_onnx(name)
        elif name == "clip_vision":
            convert_clip_vision()
        else:
            write_clip_text()


def check() -> bool:
    import coremltools as ct
    import cv2

    rng = np.random.default_rng(0)
    ok = True
    for name, (fname, shape) in ONNX_MODELS.items():
        path = ensure_yolox() if name == "yolox" else SRC / fname
        in_name, out_names = onnx_io(path)
        x = (rng.random(shape) * 255).astype(np.float32)
        if name == "eye":  # model expects (v - 127) / 255; raw 0-255 overflows to NaN
            x = (x - 127) / 255
        net = cv2.dnn.readNetFromONNX(str(path))
        net.setInput(x)
        refs = net.forward(out_names)
        ml = ct.models.MLModel(str(OUT / f"{name}.mlpackage"))
        desc = ml.get_spec().description
        outs = ml.predict({desc.input[0].name: x})
        worst = 0.0
        for n, o, ref in zip(out_names, desc.output, refs, strict=True):
            got = np.asarray(outs[o.name]).reshape(-1)
            ref = ref.reshape(-1)
            diff = float(np.abs(got - ref).max())
            cos = float(got @ ref / max(np.linalg.norm(got) * np.linalg.norm(ref), 1e-12))
            worst = diff if not np.isfinite(diff) else max(worst, diff)
            print(f"  {name}.{n}: max_abs={diff:.3e} cos={cos:.6f}")
        passed = bool(np.isfinite(worst)) and worst < 1e-3
        ok &= passed
        print(f"check {name}: {'PASS' if passed else 'FAIL'} (max_abs={worst:.3e})")
    import torch

    model = load_clip()
    x = torch.randn(1, 3, 224, 224)
    with torch.no_grad():
        ref = model.get_image_features(pixel_values=x)
    if not isinstance(ref, torch.Tensor):
        ref = ref.pooler_output
    ref = ref.numpy().reshape(-1)
    ml = ct.models.MLModel(str(OUT / "clip_vision.mlpackage"))
    got = np.asarray(ml.predict({"pixel_values": x.numpy()})["image_embeds"]).reshape(-1)
    cos = float(got @ ref / (np.linalg.norm(got) * np.linalg.norm(ref)))
    passed = cos >= 0.9999
    ok &= passed
    print(f"check clip: {'PASS' if passed else 'FAIL'} (cos={cos:.7f}, "
          f"max_abs={float(np.abs(got - ref).max()):.3e})")
    return ok


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--force", action="store_true")
    p.add_argument("--check", action="store_true", help="build missing outputs, then compare")
    args = p.parse_args()
    sys.path.insert(0, str(REPO / "src"))
    build(args.force)
    if args.check and not check():
        raise SystemExit(1)


if __name__ == "__main__":
    main()
