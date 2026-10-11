"""Check the pinned Tellus 0.8.3 coordinate projection."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from tellus_coordinates import to_blocks, to_geo  # noqa: E402


class TellusCoordinateTests(unittest.TestCase):
    def test_equator_origin_and_axis_directions(self) -> None:
        x, z = to_blocks(0, 0)
        self.assertAlmostEqual(x, 0, places=6)
        self.assertAlmostEqual(z, 0, places=6)
        self.assertGreater(to_blocks(0, 1)[0], 0)
        self.assertLess(to_blocks(1, 0)[1], 0)

    def test_moscow_matches_existing_staging_region(self) -> None:
        x, z = to_blocks(55.7558, 37.6173)
        self.assertAlmostEqual(x, 4_187_539, delta=5)
        self.assertAlmostEqual(z, -7_509_955, delta=5)
        self.assertEqual((int(x // 512), int(z // 512)), (8178, -14668))

    def test_round_trip_and_scale(self) -> None:
        x, z = to_blocks(40.7128, -74.0060, scale=10)
        self.assertAlmostEqual(to_blocks(40.7128, -74.0060)[0] / 10, x)
        self.assertAlmostEqual(to_blocks(40.7128, -74.0060)[1] / 10, z)
        latitude, longitude = to_geo(x, z, scale=10)
        self.assertAlmostEqual(latitude, 40.7128, places=6)
        self.assertAlmostEqual(longitude, -74.0060, places=6)

    def test_invalid_inputs_fail(self) -> None:
        with self.assertRaises(ValueError):
            to_blocks(91, 0)
        with self.assertRaises(ValueError):
            to_blocks(0, 0, scale=0)


if __name__ == "__main__":
    unittest.main()
