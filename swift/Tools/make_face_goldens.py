"""Write astronaut.png and faces_golden.json from the Python FaceAnalyzer (dnn backend).

Run from the repo root:
  PYTHONPATH=src uv run --no-project --python 3.12 --with opencv-contrib-python-headless \
    --with numpy --with pillow --with scikit-image swift/Tools/make_face_goldens.py
"""
import json
from pathlib import Path

import cv2
from PIL import Image
from skimage import data

from ailbum.cv.faces import FaceAnalyzer

FIXTURES = Path("swift/Tests/AilbumCoreTests/Fixtures")
Image.fromarray(data.astronaut()).save(FIXTURES / "astronaut.png")
image = cv2.imread(str(FIXTURES / "astronaut.png"), cv2.IMREAD_COLOR)

analyzer = FaceAnalyzer(Path("/Users/ivan/projects/ailbum/models"), backend="dnn")
faces = []
for item in analyzer.analyze(image):
    a = item.attributes
    faces.append(
        {
            "bbox": list(item.detection.bbox),
            "confidence": item.detection.confidence,
            "landmarks": item.detection.raw[4:14].tolist(),
            "embedding": [float(v) for v in item.embedding],
            "left_eye_open_probability": a.left_eye_open_probability,
            "right_eye_open_probability": a.right_eye_open_probability,
            "expression": a.expression,
            "expression_scores": a.expression_scores,
        }
    )
(FIXTURES / "faces_golden.json").write_text(json.dumps({"faces": faces}))
print(len(faces), [f["bbox"] for f in faces], [f["expression"] for f in faces])
