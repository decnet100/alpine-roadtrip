"""Download overview tiles for every map provider, outside the game.

The region is ``map.bbox`` in EPSG:3857, grown by 100 km of ground distance on
every side. BeamNG only composites the files that land in the HUD app folder.
It does not fetch tiles itself.

Usage:
  python tools\\fetch_region_tiles.py
  python tools\\fetch_region_tiles.py --force
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import requests
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from fetch_overview_basemap import (  # noqa: E402
    MOD_APP,
    PORTALS_YAML,
    _tile_window,
    _wgs84_envelope,
    apply_source_metadata,
)

PORTALS_JSON = ROOT / "mods" / "autoroad_alpine_rt" / "lua" / "ge" / "extensions" / "alpinert" / "portals.json"

BUFFER_KM = 100.0
ZOOM = 10
# ADAC Fahrsicherheitszentrum Augsburg, Mühlhauser Straße.
# OSM keeps a margin past this pin. The other providers stay on the 100 km buffer.
OSM_PIN_WGS84 = (48.41064, 10.93507)
OSM_PIN_MARGIN_KM = 12.0
TILE_ROOT = MOD_APP / "tilecache"
UA = {"User-Agent": "alpine-roadtrip/0.1 (regional overview cache; CC-BY basemap.at)"}

# Same ids as the HUD. basemap.at is z/y/x; OSM is z/x/y.
PROVIDERS = {
    "geoland": {
        "urls": (
            "https://mapsneu.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png",
            "https://maps.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png",
        ),
        "ext": "png",
        "attribution": "Datenquelle: basemap.at",
    },
    "geoland-aerial": {
        "urls": (
            "https://mapsneu.wien.gv.at/basemap/bmaporthofoto30cm/normal/google3857/{z}/{y}/{x}.jpeg",
            "https://maps.wien.gv.at/basemap/bmaporthofoto30cm/normal/google3857/{z}/{y}/{x}.jpeg",
        ),
        "ext": "jpeg",
        "attribution": "Datenquelle: basemap.at",
    },
    "geoland-terrain": {
        "urls": (
            "https://mapsneu.wien.gv.at/basemap/bmapgelaende/grau/google3857/{z}/{y}/{x}.jpeg",
            "https://maps.wien.gv.at/basemap/bmapgelaende/grau/google3857/{z}/{y}/{x}.jpeg",
        ),
        "ext": "jpeg",
        "attribution": "Datenquelle: basemap.at",
    },
    "osm": {
        "urls": ("https://tile.openstreetmap.org/{z}/{x}/{y}.png",),
        "ext": "png",
        "attribution": "© OpenStreetMap contributors",
    },
}


def expand_ground_km(
    west: float, south: float, east: float, north: float, km: float
) -> tuple[float, float, float, float]:
    mid = 0.5 * (south + north)
    dlat = km / 111.32
    dlon = km / (111.32 * max(0.2, math.cos(math.radians(mid))))
    return west - dlon, south - dlat, east + dlon, north + dlat


def include_pin(
    west: float, south: float, east: float, north: float, lat: float, lon: float, margin_km: float
) -> tuple[float, float, float, float]:
    dlat = margin_km / 111.32
    dlon = margin_km / (111.32 * max(0.2, math.cos(math.radians(lat))))
    return min(west, lon - dlon), min(south, lat - dlat), max(east, lon + dlon), max(north, lat + dlat)


def _is_image(blob: bytes) -> bool:
    return blob[:8] == b"\x89PNG\r\n\x1a\n" or blob[:2] == b"\xff\xd8"


def _download_one(urls: tuple[str, ...], z: int, x: int, y: int, dest: Path, force: bool) -> str:
    if dest.is_file() and dest.stat().st_size > 500 and not force:
        try:
            if _is_image(dest.read_bytes()[:8]):
                return "cached"
        except OSError:
            pass
    last = "no response"
    for tmpl in urls:
        url = tmpl.format(z=z, x=x, y=y)
        try:
            r = requests.get(url, timeout=30, headers=UA)
            r.raise_for_status()
            if not _is_image(r.content):
                last = f"not an image ({r.headers.get('content-type')})"
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(r.content)
            return "fetched"
        except Exception as ex:  # noqa: BLE001
            last = str(ex)
    print(f"  miss z{z}/{x}/{y}: {last}")
    return "miss"


def region_bbox(map_cfg: dict) -> list[float]:
    bbox = list(map_cfg.get("bbox") or [])
    if len(bbox) >= 4:
        return [float(v) for v in bbox[:4]]
    generated = json.loads(PORTALS_JSON.read_text(encoding="utf-8"))
    bbox = list(((generated.get("map") or {}).get("bbox")) or [])
    if len(bbox) < 4:
        raise SystemExit("map.bbox missing from portals.yaml and portals.json")
    return [float(v) for v in bbox[:4]]


def fetch_region_tiles(
    *,
    force: bool = False,
    buffer_km: float = BUFFER_KM,
    zoom: int = ZOOM,
    providers: tuple[str, ...] | None = None,
) -> Path:
    data = yaml.safe_load(PORTALS_YAML.read_text(encoding="utf-8")) or {}
    map_cfg = apply_source_metadata(dict(data.get("map") or {}))
    bbox = region_bbox(map_cfg)
    crs = str(map_cfg.get("crs") or "EPSG:3857")
    west, south, east, north = _wgs84_envelope(bbox, crs)
    west, south, east, north = expand_ground_km(west, south, east, north, buffer_km)
    osm_west, osm_south, osm_east, osm_north = include_pin(
        west, south, east, north, OSM_PIN_WGS84[0], OSM_PIN_WGS84[1], OSM_PIN_MARGIN_KM
    )
    z, x0, x1, y0, y1 = _tile_window(west, south, east, north, zoom)
    oz, ox0, ox1, oy0, oy1 = _tile_window(osm_west, osm_south, osm_east, osm_north, zoom)
    cols = x1 - x0 + 1
    rows = y1 - y0 + 1
    print(
        f"Region buffer {buffer_km:.0f} km  z{z}  {cols}x{rows} tiles  "
        f"WGS84=[{west:.3f},{south:.3f},{east:.3f},{north:.3f}]"
    )
    print(
        f"OSM also covers Augsburg FSZ + {OSM_PIN_MARGIN_KM:.0f} km  "
        f"z{oz} x {ox0}-{ox1} y {oy0}-{oy1}  "
        f"WGS84=[{osm_west:.3f},{osm_south:.3f},{osm_east:.3f},{osm_north:.3f}]"
    )
    selected = providers or tuple(PROVIDERS)
    previous = {}
    index_path = TILE_ROOT / "index.json"
    if index_path.is_file():
        try:
            previous = json.loads(index_path.read_text(encoding="utf-8")).get("providers") or {}
        except json.JSONDecodeError:
            previous = {}
    counts = {}
    for pid, spec in PROVIDERS.items():
        if pid not in selected:
            if pid in previous:
                counts[pid] = previous[pid]
            continue
        got = cached = missed = 0
        ext = spec["ext"]
        px0, px1, py0, py1 = (ox0, ox1, oy0, oy1) if pid == "osm" else (x0, x1, y0, y1)
        print(f"{pid} ({ext})")
        for y in range(py0, py1 + 1):
            for x in range(px0, px1 + 1):
                dest = TILE_ROOT / pid / str(z) / str(x) / f"{y}.{ext}"
                state = _download_one(tuple(spec["urls"]), z, x, y, dest, force)
                if state == "fetched":
                    got += 1
                elif state == "cached":
                    cached += 1
                else:
                    missed += 1
        counts[pid] = {"fetched": got, "cached": cached, "missed": missed, "ext": ext}
        print(f"  fetched={got} cached={cached} missed={missed}")
    index = {
        "buffer_km": buffer_km,
        "crs": crs,
        "region_bbox": [round(v, 1) for v in bbox],
        "wgs84_bbox": [west, south, east, north],
        "osm_wgs84_bbox": [osm_west, osm_south, osm_east, osm_north],
        "osm_pin_wgs84": [OSM_PIN_WGS84[0], OSM_PIN_WGS84[1]],
        "zoom": z,
        "x0": x0,
        "x1": x1,
        "y0": y0,
        "y1": y1,
        "layout": "tilecache/<provider>/<z>/<x>/<y>.<ext>",
        "providers": counts,
    }
    TILE_ROOT.mkdir(parents=True, exist_ok=True)
    index_path = TILE_ROOT / "index.json"
    index_path.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {index_path.relative_to(ROOT)}")
    return index_path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--buffer-km", type=float, default=BUFFER_KM)
    ap.add_argument("--zoom", type=int, default=ZOOM)
    ap.add_argument("--providers", nargs="*", choices=tuple(PROVIDERS), default=None)
    args = ap.parse_args()
    chosen = tuple(args.providers) if args.providers else None
    fetch_region_tiles(force=args.force, buffer_km=args.buffer_km, zoom=args.zoom, providers=chosen)


if __name__ == "__main__":
    main()
