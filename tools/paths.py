"""Repo layout. Map products stay in the terrain-worker checkout."""
from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def terrain_root() -> Path:
    """Checkout that contains config/sites and data/processed.

    Resolution order:
      1. TERRAIN_WORKER or AUTOROAD_ROOT (absolute, or relative to this repo)
      2. a sibling directory named road, terrainWorker, or terrain-worker
    """
    env = os.environ.get("TERRAIN_WORKER") or os.environ.get("AUTOROAD_ROOT")
    if env:
        p = Path(env.strip().strip('"'))
        if not p.is_absolute():
            p = ROOT / p
        p = p.resolve()
        if not (p / "config" / "sites").is_dir():
            raise SystemExit(f"TERRAIN_WORKER has no config/sites: {p}")
        return p
    for name in ("road", "terrainWorker", "terrain-worker"):
        cand = (ROOT.parent / name).resolve()
        if (cand / "config" / "sites").is_dir():
            return cand
    raise SystemExit(
        "terrain-worker checkout not found. "
        "Set TERRAIN_WORKER to the repo that contains config/sites."
    )
