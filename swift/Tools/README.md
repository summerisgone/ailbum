# Model converter

Builds `swift/Models/` (gitignored): `yunet`, `sface`, `eye`, `expression`, `yolox`,
`clip_vision` as `.mlpackage` (FLOAT32, macOS14) plus `clip_text.json`.

Rebuild everything and verify against ONNX / transformers (run from the repo root):

    PYTHONPATH=src uv run --no-project --python 3.12 --with torch --with coremltools --with onnx2torch --with onnx --with transformers --with opencv-python-headless --with numpy --with safetensors --with pillow python swift/Tools/convert_models.py --force --check

- Without `--force`, existing outputs are skipped.
- ONNX sources: `/Users/ivan/projects/ailbum/models` (override `AILBUM_ONNX_DIR`); YOLOX is downloaded and sha256-checked if missing.
- CLIP comes from the HF cache `openai/clip-vit-base-patch32` (use `HF_HUB_OFFLINE=1` offline).
- CoreML input names are the ONNX ones: yunet `input`, sface `data`, eye `input_1` (output `var_19`; ML Program forbids dots and leading digits), expression `data`, yolox `images`; clip_vision `pixel_values` -> `image_embeds`.
