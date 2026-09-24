"""Point a BeamNG level's TimeOfDay at the site bbox center."""
from __future__ import annotations

import json
from pathlib import Path

from site_coords import wgs84_center


def _read_ndjson(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def _write_ndjson(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")


def _tod_items_path(dst: Path) -> Path | None:
    for rel in (
        Path("main/MissionGroup/level_objects/sky_and_sun/items.level.json"),
        Path("main/MissionGroup/sky_and_sun/items.level.json"),
    ):
        p = dst / rel
        if p.is_file():
            return p
    return None


def patch_time_of_day(dst: Path, site: dict | None) -> None:
    """Point TimeOfDay at the site WGS84 center (northern-hemisphere sun path)."""
    if not site:
        return
    path = _tod_items_path(dst)
    if path is None:
        print("  TimeOfDay: no sky_and_sun items (skip)")
        return
    lat, lon = wgs84_center(site)
    info_path = dst / "info.json"
    year, month, day = 2026, 6, 20
    if info_path.is_file():
        info = json.loads(info_path.read_text(encoding="utf-8"))
        date = info.get("defaultDate") or {}
        year = int(date.get("year") or year)
        month = int(date.get("month") or month)
        day = int(date.get("day") or day)
    rows = _read_ndjson(path)
    changed = False
    for row in rows:
        if row.get("class") != "TimeOfDay":
            continue
        row["latitude"] = round(lat, 5)
        row["longitude"] = round(lon, 5)
        row["axisTilt"] = 23.44
        row["utcOffset"] = "2"
        row["dstRule"] = "eu"
        row["azimuthOverride"] = 0
        row["celestialProfile"] = "earth"
        row["year"] = year
        row["month"] = month
        row["day"] = day
        changed = True
    if changed:
        _write_ndjson(path, rows)
        print(f"  TimeOfDay lat={lat:.4f} lon={lon:.4f} utc+2 {year}-{month:02d}-{day:02d}")
    else:
        print("  TimeOfDay: object missing (skip)")
