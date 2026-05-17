from __future__ import annotations

import io
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import requests
from PIL import Image


class BlueMapError(RuntimeError):
    pass


_MAP_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")


@dataclass(frozen=True)
class BlueMapConfig:
    base_url: str
    map_id: str
    timeout_seconds: float = 10.0
    cache_dir: Path = Path("/tmp/bluemap-minimap-cache")

    @classmethod
    def from_env(cls) -> "BlueMapConfig":
        base_url = os.environ.get("BLUEMAP_BASE_URL", "http://bluemap.example.com:9332").rstrip("/")
        map_id = os.environ.get("BLUEMAP_MAP_ID", "world")
        timeout = float(os.environ.get("BLUEMAP_TIMEOUT_SECONDS", "10"))
        cache_dir = Path(os.environ.get("BLUEMAP_CACHE_DIR", "/tmp/bluemap-minimap-cache"))

        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("BLUEMAP_BASE_URL must be an http(s) origin")
        if not _MAP_ID_RE.fullmatch(map_id):
            raise ValueError("BLUEMAP_MAP_ID contains invalid characters")

        return cls(base_url=base_url, map_id=map_id, timeout_seconds=timeout, cache_dir=cache_dir)


def split_number_to_path(value: int) -> str:
    prefix = ""
    if value < 0:
        value = -value
        prefix = "-"
    return prefix + "/".join(str(value)) + "/"


def path_from_coords(x: int, z: int) -> str:
    path = "x" + split_number_to_path(x) + "z" + split_number_to_path(z)
    return path[:-1]


@dataclass(frozen=True)
class LowresSettings:
    tile_size: int
    lod_factor: int
    lod_count: int


class BlueMapClient:
    def __init__(self, config: BlueMapConfig):
        self.config = config
        self.session = requests.Session()
        self.config.cache_dir.mkdir(parents=True, exist_ok=True)
        self._lowres: LowresSettings | None = None

    @property
    def map_root(self) -> str:
        return f"{self.config.base_url}/maps/{self.config.map_id}"

    def settings(self) -> dict:
        response = self.session.get(
            f"{self.map_root}/settings.json",
            timeout=self.config.timeout_seconds,
        )
        response.raise_for_status()
        return response.json()

    def lowres_settings(self) -> LowresSettings:
        if self._lowres is None:
            settings = self.settings()
            lowres = settings.get("lowres") or {}
            tile_size = int((lowres.get("tileSize") or [500, 500])[0])
            lod_factor = int(lowres.get("lodFactor", 5))
            lod_count = int(lowres.get("lodCount", 3))
            self._lowres = LowresSettings(tile_size=tile_size, lod_factor=lod_factor, lod_count=lod_count)
        return self._lowres

    def tile_url(self, lod: int, tile_x: int, tile_z: int) -> str:
        return f"{self.map_root}/tiles/{lod}/{path_from_coords(tile_x, tile_z)}.png"

    def tile_cache_path(self, lod: int, tile_x: int, tile_z: int) -> Path:
        safe_name = f"lod{lod}_x{tile_x}_z{tile_z}.png".replace("-", "m")
        return self.config.cache_dir / self.config.map_id / safe_name

    def fetch_lowres_tile(self, lod: int, tile_x: int, tile_z: int) -> Image.Image | None:
        lowres = self.lowres_settings()
        if lod < 1 or lod > lowres.lod_count:
            raise BlueMapError(f"LOD must be between 1 and {lowres.lod_count}")

        cache_path = self.tile_cache_path(lod, tile_x, tile_z)
        if cache_path.exists():
            return Image.open(cache_path).convert("RGBA")

        cache_path.parent.mkdir(parents=True, exist_ok=True)
        response = self.session.get(
            self.tile_url(lod, tile_x, tile_z),
            timeout=self.config.timeout_seconds,
            headers={"accept": "image/png"},
        )
        if response.status_code == 404:
            return None
        response.raise_for_status()
        content_type = response.headers.get("content-type", "")
        if "image/png" not in content_type:
            return None

        image = Image.open(io.BytesIO(response.content)).convert("RGBA")
        image.save(cache_path)
        return image

    def live_markers(self) -> dict:
        response = self.session.get(
            f"{self.map_root}/live/markers.json",
            timeout=self.config.timeout_seconds,
        )
        response.raise_for_status()
        return response.json()

    def live_players(self) -> dict:
        response = self.session.get(
            f"{self.map_root}/live/players.json",
            timeout=self.config.timeout_seconds,
        )
        response.raise_for_status()
        return response.json()

    def world_to_lowres_tile(self, x: float, z: float, lod: int) -> tuple[int, int, float, float, float]:
        lowres = self.lowres_settings()
        lod_scale = float(lowres.lod_factor ** (lod - 1))
        world_tile_size = lowres.tile_size * lod_scale
        tile_x = math.floor(x / world_tile_size)
        tile_z = math.floor(z / world_tile_size)
        local_x = (x - tile_x * world_tile_size) / lod_scale
        local_z = (z - tile_z * world_tile_size) / lod_scale
        return tile_x, tile_z, local_x, local_z, lod_scale

    def sample_ground_height(
        self, x: float, z: float,
        chunk_radius: int = 1, radius_blocks: int | None = None,
    ) -> dict:
        """Sample surface Y from BlueMap LOD-1 lowres heightmap.

        BlueMap lowres tiles are 501x1002 PNGs: top half (y<tileSize+1) is the
        color image, bottom half is per-block metadata. The blue channel of
        the bottom half = surface y-level at that block.

        Window selection:
        - If radius_blocks is given (non-None), the sampled square is
          (2*radius_blocks+1) blocks on a side. Use this when you want
          fine-grained control (e.g. a 20x20 window for a hovering drone
          that mustn't lift to a nearby mountain peak).
        - Otherwise, chunk_radius controls a (2*chunk_radius+1) CHUNK window
          (i.e. multiples of 16). Kept for back-compat callers.

        Returns max/min ground Y across the window, plus sample/miss counters.
        """
        if radius_blocks is not None:
            if radius_blocks < 0 or radius_blocks > 256:
                raise BlueMapError("radius_blocks must be between 0 and 256")
            window_blocks = 2 * radius_blocks + 1
        else:
            if chunk_radius < 0 or chunk_radius > 8:
                raise BlueMapError("chunk_radius must be between 0 and 8")
            window_blocks = (2 * chunk_radius + 1) * 16
        lowres = self.lowres_settings()
        tile_size = lowres.tile_size
        half = window_blocks // 2
        cx, cz = math.floor(x), math.floor(z)
        wx_min, wx_max = cx - half, cx - half + window_blocks - 1
        wz_min, wz_max = cz - half, cz - half + window_blocks - 1
        tx_min = wx_min // tile_size
        tx_max = wx_max // tile_size
        tz_min = wz_min // tile_size
        tz_max = wz_max // tile_size

        max_y = None
        min_y = None
        samples = 0
        missing_tiles = 0
        for tz in range(tz_min, tz_max + 1):
            for tx in range(tx_min, tx_max + 1):
                tile = self.fetch_lowres_tile(1, tx, tz)
                if tile is None:
                    missing_tiles += 1
                    continue
                tile_wx = tx * tile_size
                tile_wz = tz * tile_size
                lx0 = max(0, wx_min - tile_wx)
                lx1 = min(tile_size, wx_max - tile_wx + 1)
                lz0 = max(0, wz_min - tile_wz)
                lz1 = min(tile_size, wz_max - tile_wz + 1)
                if lx1 <= lx0 or lz1 <= lz0:
                    continue
                meta = tile.crop((lx0, tile_size + 1 + lz0, lx1, tile_size + 1 + lz1))
                blue = meta.split()[2].tobytes()
                if not blue:
                    continue
                samples += len(blue)
                local_max = max(blue)
                local_min = min(blue)
                max_y = local_max if max_y is None else max(max_y, local_max)
                min_y = local_min if min_y is None else min(min_y, local_min)
        return {
            "groundMaxY": max_y,
            "groundMinY": min_y,
            "chunkRadius": chunk_radius if radius_blocks is None else None,
            "radiusBlocks": radius_blocks,
            "windowBlocks": window_blocks,
            "samples": samples,
            "missingTiles": missing_tiles,
        }
