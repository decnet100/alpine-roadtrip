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
from io import BytesIO
from pathlib import Path

import requests
import yaml
import numpy as np
from PIL import Image, ImageDraw, PngImagePlugin

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
# OSM and Local keep a margin past this pin. Orthophoto and Terrain stay on the 100 km buffer.
OSM_PIN_WGS84 = (48.41064, 10.93507)
OSM_PIN_MARGIN_KM = 12.0
TILE_ROOT = MOD_APP / "tilecache"
COUNTRY_FILE = ROOT / "tools" / "local_countries.json"
UA = {"User-Agent": "alpine-roadtrip/0.1 (regional overview cache; CC-BY basemap.at)"}

# basemap.at is z/y/x. swisstopo and OSM are z/x/y. The Bayern template has no extension.
GEOLAND_URLS = (
    "https://mapsneu.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png",
    "https://maps.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png",
)
LOCAL_PARTS = {
    "AT": {"urls": GEOLAND_URLS, "reuse": "geoland"},
    "CH": {
        "urls": (
            "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.pixelkarte-farbe/default/current/3857/{z}/{x}/{y}.jpeg",
        ),
        "as_png": True,
    },
    "DE": {
        "urls": (
            "https://sgx.geodatenzentrum.de/wmts_basemapde/tile/1.0.0/de_basemapde_web_raster_farbe/default/GLOBAL_WEBMERCATOR/{z}/{y}/{x}.png",
            "https://wmtsod1.bayernwolke.de/wmts/by_webkarte/smerc/{z}/{x}/{y}",
        ),
    },
    "IT": {
        "urls": (
            "https://geoservices.buergernetz.bz.it/mapproxy/root/wmts/oown-BasemapImagery:TopographicMap-IGM-25k-1986-1959-ForGeologicalMap/EPSG_3857/{z}/{x}/{y}.png",
        ),
    },
}
LOCAL_ATTRIBUTION = (
    "Datenquelle: basemap.at · © swisstopo · © GeoBasis-DE / BKG · "
    "© Bayerische Vermessungsverwaltung · © IGM"
)

# Same ids as the HUD. Local is one PNG cache assembled from the national sources.
PROVIDERS = {
    "local": {
        "urls": (),
        "ext": "png",
        "attribution": LOCAL_ATTRIBUTION,
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


def _jpeg_to_png(blob: bytes) -> bytes:
    out = BytesIO()
    Image.open(BytesIO(blob)).convert("RGB").save(out, format="PNG")
    return out.getvalue()


def _download_one(
    urls: tuple[str, ...], z: int, x: int, y: int, dest: Path, force: bool, as_png: bool = False
) -> str:
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
            blob = r.content
            if not _is_image(blob):
                last = f"not an image ({r.headers.get('content-type')})"
                continue
            if as_png and blob[:2] == b"\xff\xd8":
                blob = _jpeg_to_png(blob)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(blob)
            return "fetched"
        except Exception as ex:  # noqa: BLE001
            last = str(ex)
    print(f"  miss z{z}/{x}/{y}: {last}")
    return "miss"


_COUNTRIES: dict | None = None


def _countries() -> dict:
    global _COUNTRIES
    if _COUNTRIES is None:
        _COUNTRIES = json.loads(COUNTRY_FILE.read_text(encoding="utf-8"))
    return _COUNTRIES


def _ring_contains(ring: list, lon: float, lat: float) -> bool:
    inside = False
    j = len(ring) - 1
    for i, (xi, yi) in enumerate(ring):
        xj, yj = ring[j]
        if (yi > lat) != (yj > lat):
            if lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
        j = i
    return inside


def _country_at(lon: float, lat: float) -> str | None:
    for code, polys in _countries().items():
        for poly in polys:
            if not poly or not _ring_contains(poly[0], lon, lat):
                continue
            if any(_ring_contains(hole, lon, lat) for hole in poly[1:]):
                continue
            return code
    # Simplified borders leave a gap of a few kilometres. A tile centre in that gap
    # still belongs to the nearest of these four countries.
    best = None
    best_d = 0.15 ** 2
    for code, polys in _countries().items():
        for poly in polys:
            for ring in poly:
                for x, y in ring:
                    d = (x - lon) ** 2 + (y - lat) ** 2
                    if d < best_d:
                        best_d = d
                        best = code
    return best


def _tile_center(z: int, x: int, y: int) -> tuple[float, float]:
    n = 2 ** z
    lon = (x + 0.5) / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * (y + 0.5) / n))))
    return lat, lon


def _tile_bounds(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    n = 2 ** z

    def lat_of(ty: float) -> float:
        return math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * ty / n))))

    lon0 = x / n * 360.0 - 180.0
    lon1 = (x + 1) / n * 360.0 - 180.0
    return lon0, lat_of(y + 1), lon1, lat_of(y)


def _merc_y(lat: float) -> float:
    r = math.radians(max(-85.0, min(85.0, lat)))
    return math.log(math.tan(math.pi / 4.0 + r / 2.0))


def _to_px(lon: float, lat: float, bounds: tuple[float, float, float, float], size: int = 256) -> tuple[float, float]:
    lon0, lat_s, lon1, lat_n = bounds
    px = (lon - lon0) / (lon1 - lon0) * size
    north, south = _merc_y(lat_n), _merc_y(lat_s)
    py = (north - _merc_y(lat)) / (north - south) * size
    return px, py


def _countries_in_tile(z: int, x: int, y: int) -> list[str]:
    lon0, lat_s, lon1, lat_n = _tile_bounds(z, x, y)
    north, south = _merc_y(lat_n), _merc_y(lat_s)
    found: list[str] = []
    steps = 16
    for iy in range(steps + 1):
        my = north + (iy / steps) * (south - north)
        lat = math.degrees(2.0 * math.atan(math.exp(my)) - math.pi / 2.0)
        for ix in range(steps + 1):
            lon = lon0 + (ix / steps) * (lon1 - lon0)
            code = _country_at(lon, lat)
            if code and code not in found:
                found.append(code)
    return found


def _country_mask(code: str, bounds: tuple[float, float, float, float], size: int = 256) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    for poly in _countries().get(code, []):
        if not poly:
            continue
        exterior = [_to_px(lon, lat, bounds, size) for lon, lat in poly[0]]
        if len(exterior) >= 3:
            draw.polygon(exterior, fill=255)
        for hole in poly[1:]:
            pts = [_to_px(lon, lat, bounds, size) for lon, lat in hole]
            if len(pts) >= 3:
                draw.polygon(pts, fill=0)
    return mask


def _visible_pixels(img: Image.Image) -> np.ndarray:
    arr = np.array(img)
    rgb = arr[:, :, :3]
    black = (rgb[:, :, 0] < 16) & (rgb[:, :, 1] < 16) & (rgb[:, :, 2] < 16)
    return (arr[:, :, 3] > 16) & ~black


def _fetch_blob(urls: tuple[str, ...], z: int, x: int, y: int, as_png: bool = False) -> bytes | None:
    for tmpl in urls:
        url = tmpl.format(z=z, x=x, y=y)
        try:
            r = requests.get(url, timeout=30, headers=UA)
            r.raise_for_status()
            blob = r.content
            if not _is_image(blob):
                continue
            if as_png and blob[:2] == b"\xff\xd8":
                blob = _jpeg_to_png(blob)
            return blob
        except Exception:  # noqa: BLE001
            continue
    return None


def _layer_bytes(code: str, z: int, x: int, y: int) -> bytes | None:
    part = LOCAL_PARTS.get(code)
    if not part:
        return None
    reuse = part.get("reuse")
    if reuse:
        src = TILE_ROOT / str(reuse) / str(z) / str(x) / f"{y}.png"
        if src.is_file():
            blob = src.read_bytes()
            if len(blob) >= 32 and _is_image(blob[:8]):
                return blob
    return _fetch_blob(tuple(part["urls"]), z, x, y, as_png=bool(part.get("as_png")))


def _composite_tile(z: int, x: int, y: int, codes: list[str]) -> Image.Image | None:
    bounds = _tile_bounds(z, x, y)
    layers: list[tuple[np.ndarray, np.ndarray, np.ndarray]] = []
    for code in ("AT", "CH", "DE", "IT"):
        if code not in codes:
            continue
        blob = _layer_bytes(code, z, x, y)
        if not blob:
            print(f"  miss z{z}/{x}/{y}: no image for {code}")
            continue
        img = Image.open(BytesIO(blob)).convert("RGBA")
        if img.size != (256, 256):
            img = img.resize((256, 256), Image.Resampling.BILINEAR)
        country = np.array(_country_mask(code, bounds)) > 0
        pixels = np.array(img)
        content = _visible_pixels(img)
        layers.append((pixels, country, content))
    if not layers:
        return None
    base = np.zeros((256, 256, 4), dtype=np.uint8)
    covered = np.zeros((256, 256), dtype=bool)
    for pixels, country, content in layers:
        use = country & content
        base[use] = pixels[use]
        covered |= use
    # A country tile is empty outside its real coverage. Let the neighbour show through there.
    for pixels, _country, content in layers:
        use = (~covered) & content
        base[use] = pixels[use]
        covered |= use
    return Image.fromarray(base, mode="RGBA")


def _is_border_composite(path: Path) -> bool:
    try:
        with Image.open(path) as im:
            return im.info.get("alpine_rt") == "masked"
    except OSError:
        return False


def _reuse_cached(provider: str, z: int, x: int, y: int, dest: Path) -> bool:
    src = TILE_ROOT / provider / str(z) / str(x) / f"{y}.png"
    if not src.is_file():
        return False
    blob = src.read_bytes()
    if len(blob) < 32 or not _is_image(blob[:8]):
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(blob)
    return True


def _download_local(z: int, x: int, y: int, dest: Path, force: bool, tally: dict) -> str:
    lat, lon = _tile_center(z, x, y)
    code = _country_at(lon, lat) or "other"
    tally[code] = tally.get(code, 0) + 1
    codes = [c for c in _countries_in_tile(z, x, y) if c in LOCAL_PARTS]
    border = len(codes) > 1
    if border:
        tally["border"] = tally.get("border", 0) + 1
    if dest.is_file() and dest.stat().st_size > 32 and not force:
        try:
            if border and _is_border_composite(dest):
                return "cached"
            if not border and _is_image(dest.read_bytes()[:8]):
                return "cached"
        except OSError:
            pass
    if border:
        img = _composite_tile(z, x, y, codes)
        if img is None:
            print(f"  miss z{z}/{x}/{y}: border composite failed ({lat:.3f},{lon:.3f})")
            return "miss"
        dest.parent.mkdir(parents=True, exist_ok=True)
        meta = PngImagePlugin.PngInfo()
        meta.add_text("alpine_rt", "masked")
        img.save(dest, format="PNG", pnginfo=meta)
        return "fetched"
    part = LOCAL_PARTS.get(code)
    if not part:
        print(f"  miss z{z}/{x}/{y}: no local source for {code} ({lat:.3f},{lon:.3f})")
        return "miss"
    if not force and part.get("reuse") and _reuse_cached(part["reuse"], z, x, y, dest):
        return "cached"
    return _download_one(tuple(part["urls"]), z, x, y, dest, True, as_png=bool(part.get("as_png")))


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
        f"OSM and Local also cover Augsburg FSZ + {OSM_PIN_MARGIN_KM:.0f} km  "
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
        tally: dict[str, int] = {}
        px0, px1, py0, py1 = (ox0, ox1, oy0, oy1) if pid in ("osm", "local") else (x0, x1, y0, y1)
        print(f"{pid} ({ext})")
        for y in range(py0, py1 + 1):
            for x in range(px0, px1 + 1):
                dest = TILE_ROOT / pid / str(z) / str(x) / f"{y}.{ext}"
                if pid == "local":
                    state = _download_local(z, x, y, dest, force, tally)
                else:
                    state = _download_one(tuple(spec["urls"]), z, x, y, dest, force)
                if state == "fetched":
                    got += 1
                elif state == "cached":
                    cached += 1
                else:
                    missed += 1
        entry = {"fetched": got, "cached": cached, "missed": missed, "ext": ext}
        if pid == "local":
            entry["border_tiles"] = tally.pop("border", 0)
            entry["countries"] = tally
        counts[pid] = entry
        print(f"  fetched={got} cached={cached} missed={missed}")
        if tally:
            print("  countries " + " ".join(f"{k}={v}" for k, v in sorted(tally.items())))
        if entry.get("border_tiles"):
            print(f"  border tiles {entry['border_tiles']}")
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
