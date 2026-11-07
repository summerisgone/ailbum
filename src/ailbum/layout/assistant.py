from __future__ import annotations

import base64
import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from io import BytesIO
from typing import Any

from PIL import Image, ImageDraw, ImageFont, ImageOps

from ailbum.layout.templates import format_for, templates_for
from ailbum.story_naming import _request_json

LABELS = "ABCDEF"
MAX_REASON = 200
MAX_WISH = 300
_CONTROL = re.compile(r"[\x00-\x1f\x7f]+")


@dataclass(slots=True)
class AssistantChoice:
    index: int
    reason: str


class LayoutAssistant:
    def __init__(self, base_url: str, model: str, timeout: float = 90.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout

    def connect(self) -> bool:
        try:
            response = _request_json(f"{self.base_url}/models", timeout=min(self.timeout, 10.0))
            if not self.model:
                self.model = str(response["data"][0]["id"])
        except Exception:  # noqa: BLE001 - any failure means unavailable
            return False
        return True

    def choose(
        self,
        variants: Sequence[Any],
        paths: Mapping[int, str],
        orientation: str,
        story_title: str,
        wish: str = "",
    ) -> AssistantChoice | None:
        count = min(len(variants), len(LABELS))
        if count < 2:
            return None
        letters = ", ".join(LABELS[:count])
        prompt = (
            "На листе показаны варианты раскладки одного разворота фотоальбома, подписанные "
            f"{letters}. Сюжет: «{story_title}». Выбери вариант, который лучше читается как "
            "история и выглядит сбалансированнее: крупный кадр у главного момента, ровный "
            "ритм, без перегруза. Все варианты допустимы, лица не обрезаны. "
            + (f"Пожелание автора альбома: «{wish.strip()[:MAX_WISH]}». " if wish.strip() else "")
            + 'Верни только JSON вида {"choice":"A","reason":"коротко почему"}.'
        )
        try:
            sheet = render_variants(variants[:count], paths, orientation)
            url = "data:image/jpeg;base64," + base64.b64encode(sheet).decode("ascii")
            response = _request_json(
                f"{self.base_url}/chat/completions",
                {
                    "model": self.model,
                    "messages": [
                        {
                            "role": "user",
                            "content": [
                                {"type": "text", "text": prompt},
                                {"type": "image_url", "image_url": {"url": url}},
                            ],
                        }
                    ],
                    "temperature": 0.1,
                    "max_tokens": 200,
                    "stream": False,
                },
                timeout=self.timeout,
            )
            raw = response["choices"][0]["message"]["content"]
        except Exception:  # noqa: BLE001 - untrusted reply or server failure
            return None
        return _parse_choice(raw, count)


def _parse_choice(raw: object, count: int) -> AssistantChoice | None:
    if not isinstance(raw, str):
        return None
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", raw):
        try:
            data, _ = decoder.raw_decode(raw, match.start())
        except ValueError:
            continue
        if not isinstance(data, dict):
            continue
        letter = data.get("choice")
        if not isinstance(letter, str) or len(letter.strip()) != 1:
            continue
        index = LABELS.find(letter.strip().upper())
        if not 0 <= index < count:
            continue
        reason = data.get("reason")
        reason = _CONTROL.sub(" ", reason).strip()[:MAX_REASON] if isinstance(reason, str) else ""
        return AssistantChoice(index, reason)
    return None


def render_variants(
    variants: Sequence[Any],
    paths: Mapping[int, str],
    orientation: str,
    max_side: int = 896,
) -> bytes:
    fmt = format_for(orientation)
    by_id = {t.id: t for t in templates_for(orientation)}
    width = 1200
    height = max(1, round(width * fmt.spread_h_mm / fmt.spread_w_mm))
    scale = width / fmt.spread_w_mm
    label_h = 56
    pad = 12
    font = ImageFont.load_default(size=40)
    sheet = Image.new(
        "RGB",
        (width + 2 * pad, len(variants) * (height + label_h + pad) + pad),
        (255, 255, 255),
    )
    draw = ImageDraw.Draw(sheet)
    for number, variant in enumerate(variants):
        top = pad + number * (height + label_h + pad)
        draw.text((pad, top), LABELS[number % len(LABELS)], fill=(0, 0, 0), font=font)
        top += label_h
        draw.rectangle((pad, top, pad + width, top + height), fill=(235, 235, 235))
        template = by_id.get(variant.template_id)
        if template is not None:
            cells = {cell.index: cell for cell in template.cells}
            for placement in variant.placements:
                cell = cells.get(placement.cell_index)
                if cell is not None:
                    _paste_cell(sheet, cell.rect, placement, paths, pad, top, scale)
        draw.line(
            (pad + width // 2, top, pad + width // 2, top + height), fill=(120, 120, 120), width=2
        )
    sheet.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
    output = BytesIO()
    sheet.save(output, "JPEG", quality=85)
    return output.getvalue()


def _paste_cell(
    sheet: Image.Image,
    rect: Any,
    placement: Any,
    paths: Mapping[int, str],
    left: int,
    top: int,
    scale: float,
) -> None:
    x0, y0 = left + round(rect.x * scale), top + round(rect.y * scale)
    size = (max(1, round(rect.w * scale)), max(1, round(rect.h * scale)))
    tile = _photo_tile(paths.get(placement.image_id), placement.crop, size)
    sheet.paste(tile, (x0, y0))
    ImageDraw.Draw(sheet).rectangle(
        (x0, y0, x0 + size[0] - 1, y0 + size[1] - 1), outline=(255, 255, 255), width=3
    )


def _photo_tile(path: str | None, crop: Any, size: tuple[int, int]) -> Image.Image:
    try:
        with Image.open(path) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
    except Exception:  # noqa: BLE001
        # Missing or unreadable file: gray tile with a cross keeps the layout legible.
        tile = Image.new("RGB", size, (170, 170, 170))
        draw = ImageDraw.Draw(tile)
        draw.line((0, 0, *size), fill=(110, 110, 110), width=3)
        draw.line((0, size[1], size[0], 0), fill=(110, 110, 110), width=3)
        return tile
    w, h = image.size
    x0 = min(max(crop.x, 0.0), 1.0)
    y0 = min(max(crop.y, 0.0), 1.0)
    x1 = min(max(crop.x + crop.w, x0), 1.0)
    y1 = min(max(crop.y + crop.h, y0), 1.0)
    left, upper = int(x0 * w), int(y0 * h)
    box = (left, upper, max(left + 1, round(x1 * w)), max(upper + 1, round(y1 * h)))
    return image.crop(box).resize(size, Image.Resampling.LANCZOS)
