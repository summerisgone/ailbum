from __future__ import annotations

import base64
import json
import re
from io import BytesIO
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from PIL import Image, ImageOps

from ailbum.models import StoryRecord

_TITLE_HINTS = {
    "beach": ("пляж", "побереж", "у моря", "морской"),
    "night": ("ноч", "вечер", "лун"),
    "food": ("ед", "стол", "ужин", "обед", "завтрак", "ресторан", "бар", "морепродукт"),
    "restaurant": ("ресторан", "кафе", "бар", "стол"),
    "transport": ("дорог", "поезд", "автобус", "машин", "автомоб", "самол", "аэропорт"),
    "city": ("город", "улиц"),
    "architecture": ("архитект", "здани", "храм", "дворец"),
    "nature": ("природ", "лес", "парк", "озер", "прогул"),
    "mountains": ("горах", "горы", "горн", "скал"),
    "indoor": ("помещен", "комнат", "отел"),
    "party": ("празд", "вечерин", "день рождения"),
    "ceremony": ("церемон", "свад", "выпуск"),
    "performance": ("концерт", "выступ", "шоу"),
    "portrait_session": ("портрет", "фотосесс", "съёмк"),
    "swimming": ("купан", "плаван", "дайв"),
    "people": ("люд", "друз", "сем", "дет", "портрет", "фотосесс", "купан"),
    "animal": ("живот", "кот", "кош", "собак", "птиц"),
    "vehicle": ("машин", "автомоб", "автобус", "поезд", "лод", "самол"),
    "plant": ("растен", "цвет", "дерев"),
}


class StoryNamer:
    """Generate concise Russian story titles with a local LM Studio VLM."""

    def __init__(
        self,
        backend: str = "auto",
        base_url: str = "http://127.0.0.1:1234/v1",
        model: str = "qwen/qwen3-vl-2b",
        max_images: int = 4,
        timeout: float = 90.0,
    ) -> None:
        if backend not in {"auto", "rules", "lmstudio"}:
            raise ValueError(f"Unsupported story naming backend: {backend}")
        if not 1 <= max_images <= 8:
            raise ValueError("Story VLM image count must be between 1 and 8")
        if timeout <= 0:
            raise ValueError("Story VLM timeout must be positive")
        self.requested_backend = backend
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.max_images = max_images
        self.timeout = timeout
        self.backend = "rules"
        self.error: str | None = None

    def refine(
        self,
        stories: list[StoryRecord],
        photo_paths: dict[str, str],
    ) -> list[StoryRecord]:
        if self.requested_backend == "rules" or not stories:
            return stories
        try:
            self._connect()
        except Exception as error:
            self.error = f"{type(error).__name__}: {error}"
            if self.requested_backend == "lmstudio":
                raise RuntimeError(
                    "LM Studio недоступен. Запустите `lms server start` и загрузите VL-модель."
                ) from error
            return stories

        for story in stories:
            paths = [photo_paths[photo_id] for photo_id in story.photo_ids if photo_id in photo_paths]
            try:
                title = self._name_story(story, paths)
            except Exception as error:  # noqa: BLE001 - one failed title must not lose a run
                self.error = f"{type(error).__name__}: {error}"
                continue
            if title is not None and _title_score(title, story) >= _title_score(
                story.title, story
            ):
                story.title = title
                story.naming_model = self.model
        return stories

    def _connect(self) -> None:
        response = _request_json(f"{self.base_url}/models", timeout=min(self.timeout, 10.0))
        if not self.model:
            models = response.get("data") if isinstance(response, dict) else None
            if not isinstance(models, list) or not models:
                raise RuntimeError("В LM Studio нет доступной модели")
            self.model = str(models[0]["id"])
        self.backend = "lmstudio"

    def _name_story(self, story: StoryRecord, paths: list[str]) -> str | None:
        selected = _evenly_spaced(paths, self.max_images)
        if not selected:
            return None
        tags = ", ".join(story.scene_labels[:6] + story.object_labels[:6]) or "нет"
        prompt = (
            "Перед тобой несколько кадров одного непрерывного эпизода фотоальбома. "
            "Определи реальный сюжет по всем кадрам вместе. Дай короткое информативное "
            "название на русском языке из 2–7 слов: отрази место, время суток и занятие "
            "людей или повод, если это видно. Не используй общие названия «Событие», "
            "«Фотоистория», «Сюжет», «Встреча» без конкретного уточнения. Не считай стол "
            "или еду главным сюжетом, если большинство кадров о другом. Не выдумывай "
            f"детали. Текущее название по CV: «{story.title}». Сохрани его, если оно "
            f"точнее описывает место, время и действие. Вспомогательные CV-теги "
            f"(могут ошибаться): {tags}. "
            'Верни только JSON вида {"title":"..."}.'
        )
        content: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
        content.extend(
            {
                "type": "image_url",
                "image_url": {"url": _image_data_url(Path(path))},
            }
            for path in selected
        )
        response = _request_json(
            f"{self.base_url}/chat/completions",
            {
                "model": self.model,
                "messages": [{"role": "user", "content": content}],
                "temperature": 0.1,
                "max_tokens": 120,
                "stream": False,
            },
            timeout=self.timeout,
        )
        raw = response["choices"][0]["message"]["content"]
        return _parse_title(raw)


def _request_json(
    url: str,
    payload: dict[str, Any] | None = None,
    *,
    timeout: float,
) -> dict[str, Any]:
    data = json.dumps(payload).encode() if payload is not None else None
    request = Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST" if payload is not None else "GET",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"LM Studio вернул HTTP {error.code}: {detail[:300]}") from error
    except URLError as error:
        raise ConnectionError(f"Не удалось подключиться к LM Studio: {error.reason}") from error
    if not isinstance(result, dict):
        raise TypeError("LM Studio вернул ответ не в формате JSON-объекта")
    return result


def _image_data_url(path: Path, max_side: int = 896) -> str:
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")
        image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
        output = BytesIO()
        image.save(output, format="JPEG", quality=84, optimize=True)
    encoded = base64.b64encode(output.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{encoded}"


def _evenly_spaced(paths: list[str], limit: int) -> list[str]:
    if len(paths) <= limit:
        return paths
    if limit == 1:
        return [paths[len(paths) // 2]]
    indices = [round(index * (len(paths) - 1) / (limit - 1)) for index in range(limit)]
    return [paths[index] for index in dict.fromkeys(indices)]


def _parse_title(value: Any) -> str | None:
    if isinstance(value, list):
        value = "".join(
            str(item.get("text", "")) for item in value if isinstance(item, dict)
        )
    if not isinstance(value, str):
        return None
    match = re.search(r"\{[^{}]*\}", value, flags=re.DOTALL)
    if match is None:
        return None
    try:
        title = str(json.loads(match.group(0)).get("title", "")).strip().strip('"«»')
    except (json.JSONDecodeError, AttributeError):
        return None
    title = re.sub(r"\s+", " ", title)
    lowered = title.casefold()
    if not 3 <= len(title) <= 80:
        return None
    if lowered.startswith(("событие", "фотоистория", "сюжет", "встреча")):
        return None
    if lowered.startswith(("дай ", "как ", "совет", "лайфхак")) or "?" in title:
        return None
    return title


def _title_score(title: str, story: StoryRecord) -> float:
    lowered = title.casefold()
    if lowered.startswith(("событие", "фотоистория", "сюжет", "встреча")):
        return -10.0
    labels = story.scene_labels[:8] + story.object_labels[:8]
    matched = sum(
        any(hint in lowered for hint in _TITLE_HINTS.get(label, ()))
        for label in dict.fromkeys(labels)
    )
    word_bonus = min(0.5, len(title.split()) * 0.1)
    return matched + word_bonus
