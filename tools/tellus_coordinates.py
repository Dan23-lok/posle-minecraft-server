"""Project geographic points into Tellus 0.8.3 Mercator world coordinates.

These coordinates apply only to a world whose level.dat uses Tellus Earth with
the same world_scale and default Mercator mode. The current live world-v2 does
not meet that condition; do not paste these as teleport targets there.
"""

from __future__ import annotations

import argparse
import math


METRES_PER_DEGREE = 111_319.49166666667
MERCATOR_RADIUS = METRES_PER_DEGREE * 180 / math.pi
LATITUDE_LIMIT = 85.05112878


def to_blocks(latitude: float, longitude: float, scale: float = 1.0) -> tuple[float, float]:
    if not (math.isfinite(latitude) and math.isfinite(longitude) and math.isfinite(scale)):
        raise ValueError("Coordinates and scale must be finite")
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180 or scale <= 0:
        raise ValueError("Latitude/longitude/scale outside permitted range")
    latitude = max(-LATITUDE_LIMIT, min(LATITUDE_LIMIT, latitude))
    x = longitude * METRES_PER_DEGREE / scale
    z = -MERCATOR_RADIUS / scale * math.log(math.tan(math.pi / 4 + math.radians(latitude) / 2))
    return x, z


def to_geo(x: float, z: float, scale: float = 1.0) -> tuple[float, float]:
    if not (math.isfinite(x) and math.isfinite(z) and math.isfinite(scale)) or scale <= 0:
        raise ValueError("Block coordinates and scale must be finite; scale must be positive")
    longitude = x * scale / METRES_PER_DEGREE
    latitude = math.degrees(math.atan(math.sinh(-z * scale / MERCATOR_RADIUS)))
    return latitude, longitude


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("latitude", type=float)
    parser.add_argument("longitude", type=float)
    parser.add_argument("--scale", type=float, default=1.0, help="Real-world metres per block at equator")
    args = parser.parse_args()
    x, z = to_blocks(args.latitude, args.longitude, args.scale)
    print(f"Tellus 0.8.3 at scale={args.scale}: X={x:.3f}, Z={z:.3f}; approximate /tp X Z: {round(x)} {round(z)}")
