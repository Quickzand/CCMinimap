from __future__ import annotations

import io
import math
import os
import re
import tempfile
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import requests
from PIL import Image, UnidentifiedImageError


class BlueMapError(RuntimeError):
    pass


_MAP_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")


@dataclass(frozen=True)
class BlueMapConfig:
    base_url: str
    map_id: str
    timeout_seconds: float = 10.0
    cache_dir: Path = Path("/tmp/bluemap-minimap-cache")
    cache_ttl_seconds: float = 3600.0
    frontier_cache_ttl_seconds: float = 30.0

    @classmethod
    def from_env(cls) -> "BlueMapConfig":
        base_url = os.environ.get("BLUEMAP_BASE_URL", "http://bluemap.example.com:9332").rstrip("/")
        map_id = os.environ.get("BLUEMAP_MAP_ID", "world")
        timeout = float(os.environ.get("BLUEMAP_TIMEOUT_SECONDS", "10"))
        cache_dir = Path(os.environ.get("BLUEMAP_CACHE_DIR", "/tmp/bluemap-minimap-cache"))
        cache_ttl = float(os.environ.get("BLUEMAP_CACHE_TTL_SECONDS", "3600"))
        frontier_cache_ttl = float(os.environ.get("BLUEMAP_FRONTIER_CACHE_TTL_SECONDS", "30"))

        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("BLUEMAP_BASE_URL must be an http(s) origin")
        if not _MAP_ID_RE.fullmatch(map_id):
            raise ValueError("BLUEMAP_MAP_ID contains invalid characters")
        if cache_ttl < 0:
            raise ValueError("BLUEMAP_CACHE_TTL_SECONDS must be non-negative")
        if frontier_cache_ttl < 0:
            raise ValueError("BLUEMAP_FRONTIER_CACHE_TTL_SECONDS must be non-negative")

        return cls(base_url=base_url, map_id=map_id, timeout_seconds=timeout,
                   cache_dir=cache_dir, cache_ttl_seconds=cache_ttl,
                   frontier_cache_ttl_seconds=frontier_cache_ttl)


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


_TILE_MEM_MAX = 128   # max decoded tiles kept in memory (~2 MB each at LOD1)
_TILE_MEM_TTL = 60.0  # seconds before a memory-cached tile is considered stale


def transparent_color_pixels(image: Image.Image, tile_size: int) -> int:
    """Count fully transparent pixels in the visible BlueMap color half."""
    color_half = image.crop((0, 0, tile_size + 1, tile_size + 1))
    return color_half.getchannel("A").histogram()[0]


class BlueMapClient:
    def __init__(self, config: BlueMapConfig):
        self.config = config
        self.session = requests.Session()
        self.config.cache_dir.mkdir(parents=True, exist_ok=True)
        self._lowres: LowresSettings | None = None
        # In-memory tile cache: key → (timestamp, Image, transparent_pixels).
        # OrderedDict handles LRU eviction.
        self._tile_mem: OrderedDict[tuple, tuple[float, Image.Image, int]] = OrderedDict()

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

    def _read_cached_tile(self, cache_path: Path) -> Image.Image | None:
        """Open a cached tile, returning None if it's missing or corrupt.

        PIL's image.save() is not atomic -- it truncates the destination then
        writes. Under concurrent requests for the same tile (and any other
        crash mid-write) a reader can hit a 0-byte or partial PNG file. Treat
        that as a cache miss so the caller refetches instead of 500-ing.
        """
        try:
            return Image.open(cache_path).convert("RGBA")
        except (UnidentifiedImageError, OSError):
            return None

    def _save_tile_atomic(self, image: Image.Image, cache_path: Path) -> None:
        """Write tile to a sibling tempfile, then os.replace. Prevents the
        0-byte window concurrent writers would otherwise leave."""
        fd, tmp_name = tempfile.mkstemp(
            dir=cache_path.parent, prefix=cache_path.name + ".", suffix=".tmp",
        )
        os.close(fd)
        tmp = Path(tmp_name)
        try:
            image.save(tmp, format="PNG")
            os.replace(tmp, cache_path)
        except Exception:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            raise

    def _cache_ttl_for_tile(self, transparent_pixels: int) -> float:
        if transparent_pixels > 0:
            return self.config.frontier_cache_ttl_seconds
        return self.config.cache_ttl_seconds

    def fetch_lowres_tile(self, lod: int, tile_x: int, tile_z: int) -> Image.Image | None:
        lowres = self.lowres_settings()
        if lod < 1 or lod > lowres.lod_count:
            raise BlueMapError(f"LOD must be between 1 and {lowres.lod_count}")

        mem_key = (lod, tile_x, tile_z)
        now = time.time()

        # Hot memory cache: skip disk and network entirely for recently decoded tiles.
        if mem_key in self._tile_mem:
            ts, img, transparent_pixels = self._tile_mem[mem_key]
            ttl = min(_TILE_MEM_TTL, self._cache_ttl_for_tile(transparent_pixels))
            if now - ts < ttl:
                self._tile_mem.move_to_end(mem_key)  # LRU touch
                return img
            # Stale in memory — fall through to disk/network refresh.

        cache_path = self.tile_cache_path(lod, tile_x, tile_z)
        cache_exists = cache_path.exists()

        cached = None
        cached_transparent = 0

        # Fresh disk cache: decode once and store in memory. Frontier tiles
        # (BlueMap color pixels with alpha=0) get a much shorter TTL because
        # those transparent regions turn into the black unexplored chunks the
        # CC client sees, and they may become rendered shortly after discovery.
        if cache_exists:
            age = now - cache_path.stat().st_mtime
            cached = self._read_cached_tile(cache_path)
            if cached is not None:
                cached_transparent = transparent_color_pixels(cached, lowres.tile_size)
                if age < self._cache_ttl_for_tile(cached_transparent):
                    self._store_tile_mem(mem_key, now, cached, cached_transparent)
                    return cached
        else:
            cache_path.parent.mkdir(parents=True, exist_ok=True)

        # Stale or missing: try to refresh from upstream. On any failure
        # (network error, 5xx, non-PNG response), fall back to the stale
        # cached copy if we have one -- "last good state" is better than
        # a hole in the frame while BlueMap is down or restarting.
        try:
            response = self.session.get(
                self.tile_url(lod, tile_x, tile_z),
                timeout=self.config.timeout_seconds,
                headers={"accept": "image/png"},
            )
            if response.status_code == 404:
                if cached is not None:
                    self._store_tile_mem(mem_key, now, cached, cached_transparent)
                    return cached
                return None
            response.raise_for_status()
            content_type = response.headers.get("content-type", "")
            if "image/png" not in content_type:
                if cached is not None:
                    self._store_tile_mem(mem_key, now, cached, cached_transparent)
                    return cached
                return None

            image = Image.open(io.BytesIO(response.content)).convert("RGBA")
            transparent_pixels = transparent_color_pixels(image, lowres.tile_size)
            self._save_tile_atomic(image, cache_path)
            self._store_tile_mem(mem_key, now, image, transparent_pixels)
            return image
        except requests.RequestException:
            if cached is not None:
                self._store_tile_mem(mem_key, now, cached, cached_transparent)
                return cached
            raise

    def _store_tile_mem(self, key: tuple, ts: float, img: Image.Image, transparent_pixels: int) -> None:
        """Insert/update memory cache with LRU eviction at _TILE_MEM_MAX entries."""
        self._tile_mem[key] = (ts, img, transparent_pixels)
        self._tile_mem.move_to_end(key)
        while len(self._tile_mem) > _TILE_MEM_MAX:
            self._tile_mem.popitem(last=False)

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
