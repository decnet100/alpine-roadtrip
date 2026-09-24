"""Site CRS ↔ BeamNG terrain meters for a terrain-worker site dict."""
from __future__ import annotations


def wgs84_center(site: dict) -> tuple[float, float]:
    """BBox midpoint as (latitude, longitude) degrees."""
    from pyproj import Transformer

    xmin, ymin, xmax, ymax = map(float, site["bbox"])
    to_wgs = Transformer.from_crs(
        str(site.get("crs", "EPSG:31254")), "EPSG:4326", always_xy=True
    )
    lon, lat = to_wgs.transform(0.5 * (xmin + xmax), 0.5 * (ymin + ymax))
    return float(lat), float(lon)


class SiteCoords:
    """Map between site CRS (absolute meters) and BeamNG terrain XY."""

    def __init__(self, site: dict):
        self.site = site
        self.crs = str(site.get("crs", "EPSG:31254"))
        bbox = list(map(float, site["bbox"]))
        self.xmin, self.ymin, self.xmax, self.ymax = bbox
        self.bw = self.xmax - self.xmin
        self.bh = self.ymax - self.ymin
        bng = site.get("beamng", {}) or {}
        mpp = float(bng.get("meters_per_pixel", 1.0))
        size = int(bng.get("mask_size", 512))
        self.terrain_extent = size * mpp

    def beamng_to_crs(self, bx: float, by: float) -> tuple[float, float]:
        lx = bx / self.terrain_extent * self.bw
        ly = by / self.terrain_extent * self.bh
        return self.xmin + lx, self.ymin + ly

    def crs_to_beamng(self, x: float, y: float) -> tuple[float, float]:
        lx = x - self.xmin
        ly = y - self.ymin
        return lx / self.bw * self.terrain_extent, ly / self.bh * self.terrain_extent
