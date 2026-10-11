"""Checks for explicit Natural Earth feature joins and geometry validation."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_geometry_join import find_match, geometry_summary  # noqa: E402


def feature(code: str, adm0: str) -> dict:
    return {"properties": {"ISO_A2": code, "ADM0_A3": adm0}}


class GeometryJoinTests(unittest.TestCase):
    def test_direct_iso_and_two_explicit_fallbacks(self) -> None:
        features = [feature("US", "USA"), feature("-99", "FRA"), feature("-99", "NOR")]
        self.assertEqual(find_match("US", features), (0, "ISO_A2"))
        self.assertEqual(find_match("FR", features), (1, "ADM0_A3=FRA"))
        self.assertEqual(find_match("NO", features), (2, "ADM0_A3=NOR"))

    def test_missing_or_ambiguous_code_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "No verified"):
            find_match("AQ", [])
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            find_match("FR", [feature("-99", "FRA"), feature("-99", "FRA")])

    def test_polygon_summary_checks_coordinate_ranges(self) -> None:
        square = {"type": "Polygon", "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]]}
        self.assertEqual(geometry_summary(square), (1, 1, "5"))
        square["coordinates"][0][1][0] = 181
        with self.assertRaisesRegex(ValueError, "Invalid longitude"):
            geometry_summary(square)


if __name__ == "__main__":
    unittest.main()
