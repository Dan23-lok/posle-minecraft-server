"""Offline checks for the full-dump importer using deliberately small fixtures."""

from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from contextlib import closing
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from import_geonames import build, parse_alternate, parse_geoname, verify_raw  # noqa: E402


def place(identifier: int, country: str, code: str, population: int = 0) -> str:
    return "\t".join(
        map(str, (
            identifier, "Springfield", "Springfield", "", "42.5", "-71.2",
            "P", code, country, "", "01", "001", "", "", population,
            "", "100", "Europe/London", "2026-10-10",
        ))
    )


def fixture(root: Path, places: list[str] | None = None) -> Path:
    raw = root / "raw"
    raw.mkdir()
    with zipfile.ZipFile(raw / "allCountries.zip", "w", zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr(
            "allCountries.txt",
            "\n".join(places or [place(1, "US", "PPL"), place(2, "GB", "PPLX", 100)]) + "\n",
        )
    with zipfile.ZipFile(raw / "alternateNamesV2.zip", "w", zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr(
            "alternateNamesV2.txt",
            "10\t1\tru\tСпрингфилд\t1\t\t\t\t\t\n"
            "11\t1\ten\tSpringfield\t\t\t\t\t\t\n"
            "12\t999\ten\tOrphan Alias\t\t\t\t\t\t\n",
        )
    (raw / "admin1CodesASCII.txt").write_text("US.01\tState\tState\t400\n", encoding="utf-8")
    (raw / "admin2Codes.txt").write_text("US.01.001\tDistrict\tDistrict\t401\n", encoding="utf-8")
    (raw / "countryInfo.txt").write_text(
        "# header\n" + "\t".join(("US", "USA", "840") + ("",) * 16) + "\n",
        encoding="utf-8",
    )
    (raw / "featureCodes_en.txt").write_text("P.PPL\tpopulated place\ta place\n", encoding="utf-8")
    manifest = {"provider": "GeoNames", "files": {}}
    for file in raw.iterdir():
        content = file.read_bytes()
        manifest["files"][file.name] = {
            "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest(),
        }
    (raw / "source_manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return raw


class GeoNamesImportTests(unittest.TestCase):
    def test_import_preserves_distinct_names_feature_codes_and_nulls(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = build(fixture(root), root / "out")
            self.assertEqual(result["counts"]["geonames_source_rows"], 2)
            self.assertEqual(result["counts"]["alternate_name_source_rows"], 3)
            self.assertEqual(result["counts"]["current_candidate_settlement_rows"], 1)
            self.assertEqual(result["counts"]["pplx_section_rows"], 1)
            self.assertEqual(result["counts"]["orphan_alternate_name_rows"], 1)
            with closing(sqlite3.connect(root / "out" / "geonames.sqlite")) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM populated_places WHERE name='Springfield'").fetchone()[0], 2)
                self.assertEqual(db.execute("SELECT population, elevation FROM geonames WHERE geoname_id=1").fetchone(), (0, None))
                self.assertEqual(db.execute("SELECT russian_name_candidate FROM populated_places WHERE geoname_id=1").fetchone()[0], "Спрингфилд")
                self.assertIsNone(db.execute("SELECT russian_name_candidate FROM populated_places WHERE geoname_id=2").fetchone()[0])
                self.assertEqual(db.execute("SELECT admin1_name, admin2_name FROM populated_places_with_admin WHERE geoname_id=1").fetchone(), ("State", "District"))

    def test_duplicate_id_is_rejected_without_publishing_database(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = fixture(root, [place(1, "US", "PPL"), place(1, "GB", "PPLX")])
            with self.assertRaisesRegex(ValueError, "duplicate|UNIQUE"):
                build(raw, root / "out")
            self.assertFalse((root / "out" / "geonames.sqlite").exists())

    def test_malformed_source_row_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = fixture(root, ["1\ttoo few fields"])
            with self.assertRaisesRegex(ValueError, "expected 19"):
                build(raw, root / "out")

    def test_source_hash_change_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = fixture(root)
            with (raw / "admin2Codes.txt").open("ab") as handle:
                handle.write(b"change")
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                verify_raw(raw)

    def test_population_zero_and_missing_elevation_remain_distinct(self) -> None:
        row = parse_geoname(place(7, "US", "PPL", 0), 1)
        self.assertEqual(row[14], 0)
        self.assertIsNone(row[15])

    def test_source_rows_with_blank_feature_class_or_code_are_retained(self) -> None:
        unknown_class = place(8, "AQ", "").replace("\tP\t\tAQ\t", "\t\t\tAQ\t")
        unknown_code = place(9, "AQ", "")
        self.assertEqual(parse_geoname(unknown_class, 1)[6:8], ("", ""))
        self.assertEqual(parse_geoname(unknown_code, 2)[6:8], ("P", ""))

    def test_source_alternate_with_empty_name_is_retained(self) -> None:
        row = parse_alternate("12\t1\ten\t\t\t\t\t\t\t", 1)
        self.assertEqual(row[3], "")

    def test_completed_import_can_be_verified_without_reimporting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = fixture(root)
            first = build(raw, root / "out")
            second = build(raw, root / "out")
            self.assertEqual(first["database"]["sha256"], second["database"]["sha256"])

    def test_manifest_part_recovers_after_database_was_published(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = fixture(root)
            first = build(raw, root / "out")
            manifest = root / "out" / "catalogue_manifest.json"
            pending = root / "out" / "catalogue_manifest.json.part"
            manifest.rename(pending)
            recovered = build(raw, root / "out")
            self.assertEqual(first["database"]["sha256"], recovered["database"]["sha256"])
            self.assertTrue(manifest.is_file())
            self.assertFalse(pending.exists())


if __name__ == "__main__":
    unittest.main()
