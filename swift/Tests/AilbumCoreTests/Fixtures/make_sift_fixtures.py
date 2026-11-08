"""Run once: uv run python swift/Tests/AilbumCoreTests/Fixtures/make_sift_fixtures.py"""
import json
from pathlib import Path

import cv2
import numpy as np

from ailbum.cv.similarity import extract_geometric_features, geometric_scene_similarity

out = Path(__file__).parent


def textured(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    img = np.full((240, 320, 3), 128, np.uint8)
    for _ in range(400):
        c = (int(rng.integers(320)), int(rng.integers(240)))
        cv2.circle(img, c, int(rng.integers(2, 12)), tuple(int(v) for v in rng.integers(0, 256, 3)), -1)
    for _ in range(40):
        p = (int(rng.integers(300)), int(rng.integers(220)))
        q = (p[0] + int(rng.integers(5, 40)), p[1] + int(rng.integers(5, 30)))
        cv2.rectangle(img, p, q, tuple(int(v) for v in rng.integers(0, 256, 3)), int(rng.integers(1, 3)))
    noise = rng.normal(0, 6, img.shape)
    return np.clip(img + noise, 0, 255).astype(np.uint8)


a = textured(1)
m = cv2.getRotationMatrix2D((160, 120), 6, 0.9)
m[:, 2] += (12, 7)
b = cv2.warpAffine(a, m, (320, 240), borderMode=cv2.BORDER_REFLECT_101)
c = textured(2)
for name, img in (("a", a), ("b", b), ("c", c)):
    cv2.imwrite(str(out / f"sift_{name}.png"), img)

imgs = {n: cv2.imread(str(out / f"sift_{n}.png")) for n in "abc"}
feats = {n: extract_geometric_features(imgs[n]) for n in "abc"}
gray = cv2.cvtColor(imgs["a"], cv2.COLOR_BGR2GRAY)
kps, desc = cv2.SIFT_create(nfeatures=4000, contrastThreshold=0.02).detectAndCompute(gray, None)
order = sorted(range(len(kps)), key=lambda i: -kps[i].response)[:200]
golden = {
    "count": len(kps),
    "top": [
        {"x": kps[i].pt[0], "y": kps[i].pt[1], "size": kps[i].size, "angle": kps[i].angle,
         "response": kps[i].response, "descriptor": [float(v) for v in desc[i]]}
        for i in order
    ],
    "score_ab": geometric_scene_similarity(feats["a"], feats["b"]).score,
    "score_ac": geometric_scene_similarity(feats["a"], feats["c"]).score,
}
(out / "sift_golden.json").write_text(json.dumps(golden))
print(golden["count"], golden["score_ab"], golden["score_ac"])
