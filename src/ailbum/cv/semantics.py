from __future__ import annotations

from typing import Any

import cv2
import numpy as np
from PIL import Image

from ailbum.models import SemanticRecord, TagRecord

AESTHETIC_PROMPTS = (
    "an aesthetically pleasing, beautifully composed high quality photograph",
    "an unattractive, badly composed low quality snapshot",
)
SCENE_PROMPTS = {
    "indoor": "an indoor scene inside a room or building",
    "nature": "a natural landscape, forest, field or wilderness",
    "city": "an urban city or street scene",
    "architecture": "an architectural scene focused on a building or interior design",
    "food": "a food, meal or drink scene",
    "transport": "a transport, road, railway, airplane or vehicle scene",
    "party": "a birthday, wedding reception, holiday party or celebration",
    "ceremony": "a formal ceremony, wedding vows, graduation or award presentation",
    "performance": "a concert, stage performance, show or live entertainment",
    "portrait_session": "a posed portrait session or deliberate photo shoot with people",
    "swimming": "people swimming, bathing or playing in water",
    "restaurant": "people dining together in a restaurant, cafe or at a decorated table",
    "sightseeing": "tourists visiting a landmark or exploring a travel destination",
    "hotel": "a hotel, resort, guest room or holiday accommodation scene",
    "beach": "a beach or seaside scene",
    "mountains": "a mountain scene",
    "night": "a night-time or low-light scene",
}
OBJECT_PROMPTS = {
    "people": "a photo containing one or more people",
    "animal": "a photo containing an animal",
    "food": "a photo containing food or a drink",
    "vehicle": "a photo containing a car, bicycle, boat, train or airplane",
    "building": "a photo containing a building",
    "plant": "a photo containing flowers, trees or plants",
    "furniture": "a photo containing furniture",
    "screen_or_document": "a photo containing a screen, sign or document",
}


class SemanticAnalyzer:
    """Optional local CLIP zero-shot scorer loaded lazily through Transformers."""

    def __init__(self, backend: str, model_name: str, threshold: float, top_k: int) -> None:
        if backend not in {"auto", "clip", "off"}:
            raise ValueError(f"Unsupported semantic backend: {backend}")
        if not 0.0 <= threshold <= 1.0:
            raise ValueError("Semantic threshold must be between 0 and 1")
        if top_k < 1:
            raise ValueError("Semantic top-k must be at least 1")
        self.requested_backend = backend
        self.model_name = model_name
        self.threshold = threshold
        self.top_k = top_k
        self.backend = "off"
        self.error: str | None = None
        self._torch: Any = None
        self._processor: Any = None
        self._model: Any = None
        if backend == "off":
            return
        try:
            import torch
            from transformers import AutoModelForZeroShotImageClassification, AutoProcessor

            self._torch = torch
            self._processor = AutoProcessor.from_pretrained(model_name)
            self._model = AutoModelForZeroShotImageClassification.from_pretrained(model_name)
            self._model.eval()
            self.backend = "clip"
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"
            if backend == "clip":
                raise RuntimeError(
                    "CLIP backend is unavailable. Install the 'ml' extra and make sure the "
                    f"model can be loaded: {model_name}"
                ) from error

    @property
    def available(self) -> bool:
        return self.backend == "clip"

    def analyze(self, image: np.ndarray) -> SemanticRecord:
        if not self.available:
            return SemanticRecord(aesthetic_score=None, model=None)
        prompts = [
            *AESTHETIC_PROMPTS,
            *SCENE_PROMPTS.values(),
            *OBJECT_PROMPTS.values(),
        ]
        rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        inputs = self._processor(
            text=prompts,
            images=Image.fromarray(rgb),
            return_tensors="pt",
            padding=True,
        )
        with self._torch.inference_mode():
            logits = self._model(**inputs).logits_per_image[0].detach().float().cpu().numpy()
        aesthetic = _softmax(logits[:2])
        scene_start = 2
        object_start = scene_start + len(SCENE_PROMPTS)
        scenes = _rank_tags(
            tuple(SCENE_PROMPTS), logits[scene_start:object_start], self.threshold, self.top_k
        )
        objects = _rank_tags(
            tuple(OBJECT_PROMPTS), logits[object_start:], self.threshold, self.top_k
        )
        return SemanticRecord(
            aesthetic_score=round(float(aesthetic[0]), 4),
            model=self.model_name,
            scenes=scenes,
            objects=objects,
        )


def _rank_tags(
    labels: tuple[str, ...], logits: np.ndarray, threshold: float, top_k: int
) -> list[TagRecord]:
    probabilities = _softmax(logits)
    ordered = np.argsort(probabilities)[::-1]
    result = [
        TagRecord(label=labels[int(index)], confidence=round(float(probabilities[index]), 4))
        for index in ordered
        if probabilities[index] >= threshold
    ]
    return result[:top_k]


def _softmax(values: np.ndarray) -> np.ndarray:
    shifted = np.asarray(values, dtype=np.float64) - float(np.max(values))
    exponential = np.exp(shifted)
    return exponential / exponential.sum()
