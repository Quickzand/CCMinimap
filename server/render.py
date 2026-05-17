from __future__ import annotations

import math
from dataclasses import dataclass

from PIL import Image

from bluemap import BlueMapClient
from cc_palette import MAP_PALETTE, palette_image


SUB_W = 2
SUB_H = 3


@dataclass(frozen=True)
class FrameRequest:
    x: float
    z: float
    width: int = 80
    height: int = 48
    lod: int = 1
    blocks_per_pixel: float = 2.0  # blocks per *sub-pixel*


def parse_frame_request(args) -> FrameRequest:
    def number(name, default, minimum, maximum):
        raw = args.get(name, default)
        try:
            parsed = float(raw)
        except (TypeError, ValueError):
            raise ValueError(f"{name} must be numeric")
        if not math.isfinite(parsed) or parsed < minimum or parsed > maximum:
            raise ValueError(f"{name} must be between {minimum} and {maximum}")
        return parsed

    def integer(name, default, minimum, maximum):
        return int(number(name, default, minimum, maximum))

    return FrameRequest(
        x=number("x", 0.0, -30_000_000, 30_000_000),
        z=number("z", 0.0, -30_000_000, 30_000_000),
        width=integer("w", 80, 4, 240),
        height=integer("h", 48, 3, 160),
        lod=integer("lod", 1, 1, 3),
        blocks_per_pixel=number("bpp", 2.0, 0.25, 128.0),
    )


def _paste_tile(client, canvas, lod, tile_x, tile_z, origin_x, origin_z):
    lowres = client.lowres_settings()
    _, _, _, _, lod_scale = client.world_to_lowres_tile(0, 0, lod)
    tile_world = lowres.tile_size * lod_scale
    tile = client.fetch_lowres_tile(lod, tile_x, tile_z)
    if tile is None:
        return
    color_half = tile.crop((0, 0, lowres.tile_size + 1, lowres.tile_size + 1))
    px = round((tile_x * tile_world - origin_x) / lod_scale)
    py = round((tile_z * tile_world - origin_z) / lod_scale)
    canvas.alpha_composite(color_half, (px, py))


def render_subpixel_image(client: BlueMapClient, req: FrameRequest) -> Image.Image:
    """Returns RGB image at sub-pixel resolution: (width*2) x (height*3)."""
    lowres = client.lowres_settings()
    lod_scale = float(lowres.lod_factor ** (req.lod - 1))
    sub_w = req.width * SUB_W
    sub_h = req.height * SUB_H

    crop_world_w = sub_w * req.blocks_per_pixel
    crop_world_h = sub_h * req.blocks_per_pixel
    source_px_w = max(1, math.ceil(crop_world_w / lod_scale))
    source_px_h = max(1, math.ceil(crop_world_h / lod_scale))

    SAFE_PIXELS = 4_000_000
    if source_px_w * source_px_h > SAFE_PIXELS:
        suggested = req.lod + 1 if req.lod < 3 else 3
        raise ValueError(
            f"frame too large at lod={req.lod} (would need "
            f"{source_px_w}x{source_px_h} source pixels); try lod={suggested}"
        )

    origin_x = req.x - crop_world_w / 2
    origin_z = req.z - crop_world_h / 2

    canvas = Image.new("RGBA", (source_px_w + 4, source_px_h + 4), (0, 0, 0, 255))
    tile_world = lowres.tile_size * lod_scale
    min_tile_x = math.floor(origin_x / tile_world)
    max_tile_x = math.floor((origin_x + crop_world_w) / tile_world)
    min_tile_z = math.floor(origin_z / tile_world)
    max_tile_z = math.floor((origin_z + crop_world_h) / tile_world)

    for tz in range(min_tile_z, max_tile_z + 1):
        for tx in range(min_tile_x, max_tile_x + 1):
            _paste_tile(client, canvas, req.lod, tx, tz, origin_x, origin_z)

    image = canvas.crop((0, 0, source_px_w, source_px_h)).convert("RGB")
    return image.resize((sub_w, sub_h), Image.Resampling.BILINEAR)


def quantize_to_palette(image: Image.Image) -> Image.Image:
    """Floyd-Steinberg dither to MAP_PALETTE; returns 'P' image with indices 0-15."""
    return image.convert("RGB").quantize(palette=palette_image(), dither=Image.Dither.NONE)


_PALETTE_RGB: tuple[tuple[int, int, int], ...] = tuple(c.rgb for c in MAP_PALETTE)
_HEX = "0123456789abcdef"


def encode_blit(quant: Image.Image, cell_w: int, cell_h: int) -> tuple[list[str], list[str], list[str]]:
    """Pack a (cell_w*2, cell_h*3) palette image into per-cell teletext blit triples.

    Returns (text, fg, bg) — each a list of cell_h strings, cell_w bytes long.
    text bytes are 0x40 + 5-bit pattern; the client adds 0x40 to recover the real
    teletext char (0x80-0x9F). fg/bg use CC palette codes 0-f.
    """
    sub_w = cell_w * SUB_W
    sub_h = cell_h * SUB_H
    pix = [(i if i < 16 else 15) for i in quant.getdata()]
    assert len(pix) == sub_w * sub_h, f"size mismatch {len(pix)} vs {sub_w*sub_h}"

    text_rows: list[str] = []
    fg_rows: list[str] = []
    bg_rows: list[str] = []

    palette = _PALETTE_RGB
    for cy in range(cell_h):
        text_chars: list[str] = []
        fg_chars: list[str] = []
        bg_chars: list[str] = []
        py0 = cy * SUB_H
        row0 = py0 * sub_w
        row1 = (py0 + 1) * sub_w
        row2 = (py0 + 2) * sub_w
        for cx in range(cell_w):
            px0 = cx * SUB_W
            cell = (
                pix[row0 + px0], pix[row0 + px0 + 1],
                pix[row1 + px0], pix[row1 + px0 + 1],
                pix[row2 + px0], pix[row2 + px0 + 1],
            )
            counts: dict[int, int] = {}
            for p in cell:
                counts[p] = counts.get(p, 0) + 1
            ranked = sorted(counts.keys(), key=lambda c: -counts[c])
            bg = ranked[0]
            fg = ranked[1] if len(ranked) > 1 else bg

            if fg == bg:
                pattern = 0
            else:
                fg_rgb = palette[fg]
                bg_rgb = palette[bg]
                pattern = 0
                for i, p in enumerate(cell):
                    if p == fg:
                        pattern |= 1 << i
                    elif p != bg:
                        prgb = palette[p]
                        d_fg = (prgb[0]-fg_rgb[0])**2 + (prgb[1]-fg_rgb[1])**2 + (prgb[2]-fg_rgb[2])**2
                        d_bg = (prgb[0]-bg_rgb[0])**2 + (prgb[1]-bg_rgb[1])**2 + (prgb[2]-bg_rgb[2])**2
                        if d_fg < d_bg:
                            pattern |= 1 << i

            if pattern & 0x20:
                pattern ^= 0x3F
                fg, bg = bg, fg

            text_chars.append(chr(0x40 + pattern))
            fg_chars.append(_HEX[fg])
            bg_chars.append(_HEX[bg])
        text_rows.append("".join(text_chars))
        fg_rows.append("".join(fg_chars))
        bg_rows.append("".join(bg_chars))

    return text_rows, fg_rows, bg_rows
