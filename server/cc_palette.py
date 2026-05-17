from __future__ import annotations
from dataclasses import dataclass

from PIL import Image


@dataclass(frozen=True)
class CCColor:
    name: str
    code: str
    rgb: tuple[int, int, int]


# Map-tuned palette. Order matches CC slots 0-15 (white=2^0, orange=2^1, ...).
MAP_PALETTE: tuple[CCColor, ...] = (
    CCColor("snow",      "0", (240, 240, 240)),
    CCColor("sand",      "1", (232, 214, 158)),
    CCColor("lava",      "2", (208,  80,  64)),
    CCColor("shoal",     "3", (160, 208, 240)),
    CCColor("plains",    "4", (156, 195,  74)),
    CCColor("forest",    "5", ( 58, 110,  31)),
    CCColor("pale",      "6", (207, 216, 156)),
    CCColor("darkstone", "7", ( 58,  58,  58)),
    CCColor("stone",     "8", (140, 140, 140)),
    CCColor("ocean",     "9", ( 26,  76, 124)),
    CCColor("midwater",  "a", ( 50, 110, 160)),
    CCColor("water",     "b", ( 64, 128, 192)),
    CCColor("dirt",      "c", (140,  90,  45)),
    CCColor("leaf",      "d", (101, 176,  64)),
    CCColor("brick",     "e", (176,  80,  32)),
    CCColor("void",      "f", ( 15,  15,  15)),
)


_PALETTE_IMAGE: Image.Image | None = None


def palette_image() -> Image.Image:
    global _PALETTE_IMAGE
    if _PALETTE_IMAGE is None:
        p = Image.new("P", (1, 1))
        flat: list[int] = []
        for c in MAP_PALETTE:
            flat.extend(c.rgb)
        last = MAP_PALETTE[-1].rgb
        while len(flat) < 768:
            flat.extend(last)
        p.putpalette(flat)
        _PALETTE_IMAGE = p
    return _PALETTE_IMAGE
