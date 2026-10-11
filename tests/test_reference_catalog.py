"""Checks for the pinned, source-derived Earth reference catalogues."""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "geodata" / "reference"
SCRIPT = ROOT / "tools" / "extract_reference_catalog.py"


class ReferenceCatalogueTests(unittest.TestCase):
    def test_committed_country_registry_has_exact_stated_scope(self):
        countries = json.loads((REFERENCE / "countries_195_reference.json").read_text(encoding="utf-8"))
        self.assertEqual(len(countries), 195)
        self.assertEqual(len({row["iso2"] for row in countries}), 195)
        self.assertEqual(sum(row["un_status"] == "member_state" for row in countries), 193)
        self.assertEqual(sum(row["un_status"] == "observer_state" for row in countries), 2)
        self.assertEqual(
            {region: sum(row["m49_broad_region"] == region for row in countries)
             for region in ("Africa", "Americas", "Asia", "Europe", "Oceania")},
            {"Africa": 54, "Americas": 35, "Asia": 48, "Europe": 44, "Oceania": 14},
        )
        by_code = {row["iso2"]: row for row in countries}
        self.assertEqual(by_code["RU"]["m49_broad_region"], "Europe")
        self.assertEqual(by_code["TR"]["m49_broad_region"], "Asia")
        self.assertEqual(by_code["PS"]["un_status"], "observer_state")
        for row in countries:
            self.assertTrue(row["listed_in_registry"])
            self.assertFalse(row["geometry_loaded"])
            self.assertFalse(row["terrain_generated"])
            self.assertFalse(row["spawn_validated"])
            self.assertIsNone(row["source_settlement_count"])
            self.assertIsNone(row["wup_urban_centre_count"])

    def test_areas_and_extra_code_are_distinct(self):
        areas = json.loads((REFERENCE / "areas_outside_195_baseline.json").read_text(encoding="utf-8"))
        xk = json.loads((REFERENCE / "geonames_xk_note.json").read_text(encoding="utf-8"))
        countries = json.loads((REFERENCE / "countries_195_reference.json").read_text(encoding="utf-8"))
        codes = {row["iso2"] for row in countries}
        self.assertEqual(len(areas), 54)
        self.assertEqual(len({row["code"] for row in areas}), 54)
        self.assertTrue({row["code"] for row in areas}.isdisjoint(codes))
        self.assertNotIn("XK", {row["code"] for row in areas})
        self.assertEqual(xk["code"], "XK")
        self.assertEqual(xk["catalog_kind"], "geonames_extra_code")
        for row in areas + [xk]:
            self.assertTrue(row["listed_in_registry"])
            self.assertFalse(row["geometry_loaded"])
            self.assertFalse(row["terrain_generated"])
            self.assertFalse(row["spawn_validated"])

    def test_manifest_matches_byte_exact_output_files(self):
        manifest = json.loads((REFERENCE / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["counts"]["baseline_states"], 195)
        self.assertEqual(manifest["counts"]["iso_areas_outside_baseline"], 54)
        self.assertEqual(manifest["counts"]["geonames_extra_codes"], 1)
        for item in manifest["outputs"]:
            data = (REFERENCE / item["file"]).read_bytes()
            self.assertEqual(len(data), item["bytes"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])
        self.assertEqual(len(manifest["sources"]), 2)
        self.assertTrue(all(len(item["sha256"]) == 64 for item in manifest["sources"]))

    def test_extractor_rejects_duplicate_country_code(self):
        english = """COUNTRY CHECKLIST — ALL 195 BASELINE ENTRIES
ISO2 | English name | Russian name | UN status | M49 region | reference locality
AA | A | А | member_state | Asia | Locality
AA | B | Б | observer_state | Asia | Locality
The country CSV/JSON retains original source-place fields and qualifications.
"""
        russian = """ПРИЛОЖЕНИЕ В. ДОПОЛНИТЕЛЬНЫЕ ГЕОГРАФИЧЕСКИЕ ЗАПИСИ
ZZ: Область / Area
XK: Косово / Kosovo
ИСТОЧНИКИ И ПРЕДЕЛЫ ПРОВЕРКИ
"""
        with tempfile.TemporaryDirectory() as tmp:
            source_dir = Path(tmp)
            en_file = source_dir / "en.txt"
            ru_file = source_dir / "ru.txt"
            en_file.write_text(english, encoding="utf-8")
            ru_file.write_text(russian, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--en-source", str(en_file),
                 "--ru-source", str(ru_file), "--out", str(source_dir / "out")],
                capture_output=True, text=True, encoding="utf-8", check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
