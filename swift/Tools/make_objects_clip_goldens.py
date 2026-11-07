"""Write objects_clip_golden.json from the Python ObjectDetector and SemanticAnalyzer.

Run from the repo root (astronaut.png comes from make_face_goldens.py):
  HF_HUB_OFFLINE=1 PYTHONPATH=src uv run --no-project --python 3.12 --with torch --with transformers \
    --with opencv-contrib-python-headless --with numpy --with pillow swift/Tools/make_objects_clip_goldens.py
"""
import json
from pathlib import Path

import cv2

from ailbum.cv.objects import ObjectDetector
from ailbum.cv.semantics import SemanticAnalyzer

FIXTURES = Path("swift/Tests/AilbumCoreTests/Fixtures")
bgr = cv2.imread(str(FIXTURES / "astronaut.png"), cv2.IMREAD_COLOR)
rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)

objects = ObjectDetector(Path("/Users/ivan/projects/ailbum/models")).detect(rgb)
clip = SemanticAnalyzer("clip", "openai/clip-vit-base-patch32", 0.15, 3, device="cpu")
sem = clip.analyze(bgr)

golden = {
    "objects": [{"label": o.label, "score": o.score, "bbox": list(o.bbox)} for o in objects],
    "semantic": {
        "aesthetic_score": sem.aesthetic_score,
        "scenes": [{"label": t.label, "confidence": t.confidence} for t in sem.scenes],
        "objects": [{"label": t.label, "confidence": t.confidence} for t in sem.objects],
        "embedding": sem.embedding,
    },
}
(FIXTURES / "objects_clip_golden.json").write_text(json.dumps(golden))
print(len(objects), [(o.label, round(o.score, 3)) for o in objects], sem.aesthetic_score, sem.scenes)
