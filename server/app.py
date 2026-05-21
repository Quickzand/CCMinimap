from __future__ import annotations

import io
import json
import math
import re
import os
import time

from flask import Flask, Response, jsonify, request, send_file
from PIL import Image
from requests import RequestException

from bluemap import BlueMapClient, BlueMapConfig, BlueMapError
from cc_palette import MAP_PALETTE
from render import encode_blit, parse_frame_request, quantize_to_palette, render_subpixel_image

# Rendered-frame cache: skip all PIL work when the same position/zoom is
# requested again within the TTL.  Key is quantised to one bpp-unit grid so
# sub-block ship wobble doesn't bust the cache on every tick.
_FRAME_CACHE_TTL = 1.0   # seconds a rendered frame stays valid
_FRAME_CACHE_MAX = 256   # client fetches 9 tiles per ship; raised from 64 to fit several ships
_frame_cache: dict[tuple, tuple[float, dict]] = {}
_frame_cache_order: list[tuple] = []


def _frame_cache_key(req) -> tuple:
    snap = req.blocks_per_pixel
    return (
        math.floor(req.x / snap),
        math.floor(req.z / snap),
        req.width,
        req.height,
        req.lod,
        req.blocks_per_pixel,
    )


def _frame_cache_get(key: tuple) -> dict | None:
    entry = _frame_cache.get(key)
    if entry and time.time() - entry[0] < _FRAME_CACHE_TTL:
        return entry[1]
    return None


def _frame_cache_put(key: tuple, result: dict) -> None:
    _frame_cache[key] = (time.time(), result)
    if key in _frame_cache_order:
        _frame_cache_order.remove(key)
    _frame_cache_order.append(key)
    while len(_frame_cache_order) > _FRAME_CACHE_MAX:
        old = _frame_cache_order.pop(0)
        _frame_cache.pop(old, None)


def create_app() -> Flask:
    app = Flask(__name__)
    client = BlueMapClient(BlueMapConfig.from_env())

    @app.after_request
    def security_headers(response):
        response.headers["x-content-type-options"] = "nosniff"
        response.headers["cache-control"] = "no-store"
        return response

    @app.get("/health")
    def health():
        return jsonify({"ok": True})

    @app.get("/info")
    def info():
        settings = client.settings()
        lowres = client.lowres_settings()
        return jsonify({
            "map": client.config.map_id,
            "name": settings.get("name"),
            "lowres": {
                "tileSize": lowres.tile_size,
                "lodFactor": lowres.lod_factor,
                "lodCount": lowres.lod_count,
            },
            "subpixel": {"w": 2, "h": 3},
            "palette": [f"{c.rgb[0]:02X}{c.rgb[1]:02X}{c.rgb[2]:02X}" for c in MAP_PALETTE],
        })

    @app.get("/frame")
    def frame():
        try:
            req = parse_frame_request(request.args)
            key = _frame_cache_key(req)
            cached = _frame_cache_get(key)
            if cached is not None:
                return jsonify(cached)
            image = render_subpixel_image(client, req)
            quant = quantize_to_palette(image)
            text, fg, bg = encode_blit(quant, req.width, req.height)
            result = {
                "w": req.width,
                "h": req.height,
                "x": req.x,
                "z": req.z,
                "text": text,
                "fg": fg,
                "bg": bg,
            }
            _frame_cache_put(key, result)
            return jsonify(result)
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502

    @app.get("/debug.png")
    def debug_png():
        try:
            req = parse_frame_request(request.args)
            scale = max(1, min(8, int(request.args.get("scale", "4"))))
            image = render_subpixel_image(client, req)
            quant = quantize_to_palette(image)
            rgb = quant.convert("RGB")
            rgb = rgb.resize((rgb.width * scale, rgb.height * scale), Image.Resampling.NEAREST)
            buffer = io.BytesIO()
            rgb.save(buffer, format="PNG")
            buffer.seek(0)
            return send_file(buffer, mimetype="image/png")
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502


    _players_cache = {"data": None, "ts": 0.0}
    _PLAYERS_TTL = 1.0

    @app.get("/players")
    def players():
        now = time.time()
        if now - _players_cache["ts"] > _PLAYERS_TTL:
            try:
                _players_cache["data"] = client.live_players()
                _players_cache["ts"] = now
            except (RequestException, BlueMapError) as error:
                return jsonify({"error": str(error)}), 502
        return jsonify(_players_cache["data"] or {"players": []})

    def _bm_marker_waypoints():
        try:
            sets = client.live_markers() or {}
        except (RequestException, BlueMapError):
            return []
        out = []
        for set_id, mset in sets.items():
            if not isinstance(mset, dict):
                continue
            for marker_id, marker in (mset.get("markers") or {}).items():
                pos = marker.get("position") or {}
                if "x" in pos and "z" in pos:
                    out.append({
                        "name": marker.get("label") or marker_id,
                        "x": pos["x"],
                        "z": pos["z"],
                        "color": marker.get("lineColor") or marker.get("fillColor") or "yellow",
                        "source": "bluemap",
                    })
        return out

    def _file_waypoints():
        path = os.environ.get("WAYPOINTS_FILE", "/app/waypoints.json")
        try:
            with open(path) as f:
                data = json.load(f)
            if isinstance(data, list):
                return [dict(w, source="file") for w in data if isinstance(w, dict)]
        except FileNotFoundError:
            pass
        except (json.JSONDecodeError, OSError):
            return []
        return []

    @app.get("/waypoints")
    def waypoints():
        return jsonify(_file_waypoints() + _bm_marker_waypoints())

    @app.get("/height")
    def height():
        try:
            def number(name, default, lo, hi):
                raw = request.args.get(name, default)
                v = float(raw)
                if v < lo or v > hi:
                    raise ValueError(f"{name} out of range [{lo}, {hi}]")
                return v
            x = number("x", 0.0, -30_000_000, 30_000_000)
            z = number("z", 0.0, -30_000_000, 30_000_000)
            r = int(number("r", 1, 0, 8))
            result = client.sample_ground_height(x, z, chunk_radius=r)
            result["x"] = x
            result["z"] = z
            return jsonify(result)
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502

    # Placeholders the .lua files carry instead of hardcoded values; substituted
    # here at serve time from the deployment's env. Keeps source clean and lets
    # one server image serve many installs.
    _CLIENT_SUBS = {
        "__SERVER_URL__": os.environ.get("CLIENT_SERVER_URL", ""),
        "__PLAYER_NAME__": os.environ.get("CLIENT_PLAYER_NAME", ""),
    }

    def serve_lua(path):
        with open(path) as f:
            content = f.read()
        for marker, value in _CLIENT_SUBS.items():
            content = content.replace(marker, value)
        return Response(content, mimetype="text/plain; charset=utf-8")

    @app.get("/startup.lua")
    def startup_lua():
        return serve_lua("/app/computercraft/startup.lua")

    @app.get("/config.defaults")
    def config_defaults():
        try:
            with open("/app/computercraft/minimap.lua") as f:
                lua = f.read()
        except OSError as error:
            return jsonify({"error": str(error)}), 500
        match = re.search(r"f\.write\(\[\[(.+?)\]\]\)", lua, re.DOTALL)
        if not match:
            return jsonify({"error": "no default config block found"}), 500
        try:
            return jsonify(json.loads(match.group(1)))
        except json.JSONDecodeError as error:
            return jsonify({"error": f"default config is not valid JSON: {error}"}), 500

    # Pocket cares about a tiny subset of the ship's config: just rendering bits.
    # All controller/peripheral tunables (liftKp, channels, hoverBurnerLevel, ...)
    # live on the ship and reach the pocket via rednet broadcasts.
    _POCKET_KEYS = {
        "needleLength",
        "showAltitudeTape",
        "maxAltitude",
        "airshipName",     # must match ship's value to discover it
        # Pocket holds the password in plaintext (its threat model permits it);
        # the ship stores only the SHA-256 hash and verifies on receive.
        "controlSecret",
    }

    @app.get("/config.defaults.pocket")
    def config_defaults_pocket():
        try:
            with open("/app/computercraft/minimap.lua") as f:
                lua = f.read()
        except OSError as error:
            return jsonify({"error": str(error)}), 500
        match = re.search(r"f\.write\(\[\[(.+?)\]\]\)", lua, re.DOTALL)
        if not match:
            return jsonify({"error": "no default config block found"}), 500
        try:
            full = json.loads(match.group(1))
        except json.JSONDecodeError as error:
            return jsonify({"error": f"default config is not valid JSON: {error}"}), 500
        return jsonify({k: v for k, v in full.items() if k in _POCKET_KEYS})

    @app.get("/minimap.lua")
    def minimap_lua():
        return serve_lua("/app/computercraft/minimap.lua")

    @app.get("/minimap-pocket.lua")
    def minimap_pocket_lua():
        # Same file content as /minimap.lua; minimap.lua branches on pocket~=nil.
        # Served under a second URL so the pocket can keep a distinct local
        # filename and config file.
        return serve_lua("/app/computercraft/minimap.lua")

    @app.get("/startup-pocket.lua")
    def startup_pocket_lua():
        return serve_lua("/app/computercraft/startup-pocket.lua")

    @app.get("/ship.lua")
    def ship_lua():
        return serve_lua("/app/computercraft/ship.lua")

    @app.get("/lift.lua")
    def lift_lua():
        return serve_lua("/app/computercraft/lift.lua")

    @app.get("/altitude.lua")
    def altitude_lua():
        return serve_lua("/app/computercraft/altitude.lua")

    @app.get("/cfgutil.lua")
    def cfgutil_lua():
        return serve_lua("/app/computercraft/cfgutil.lua")

    @app.get("/sha256.lua")
    def sha256_lua():
        return serve_lua("/app/computercraft/sha256.lua")

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5055"))
    app.run(host="0.0.0.0", port=port)
