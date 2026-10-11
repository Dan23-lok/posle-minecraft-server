import csv
import gzip
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from tools.import_wup2025 import build, load_2025

HEADER = [
    "LocID", "Location", "ISO3_Code", "ISO2_Code", "City_Code", "City_Name",
    "Year", "PWCent_Latitude", "PWCent_Longitude", "Pop", "TimeMid",
    "Pop_plausibility", "AREA_km2", "BU_km2", "Capital", "Notes",
]


def make_row(**changes):
    row = {
        "LocID": "1", "Location": "Aland", "ISO3_Code": "ALA", "ISO2_Code": "AX",
        "City_Code": "10", "City_Name": "A-City", "Year": "2025",
        "PWCent_Latitude": "1", "PWCent_Longitude": "2", "Pop": "55.3",
        "TimeMid": "2025.5", "Pop_plausibility": "High", "AREA_km2": "12",
        "BU_km2": "3", "Capital": "0", "Notes": "",
    }
    row.update(changes)
    return row


def write_source(path: Path, rows):
    with gzip.open(path, "wt", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER)
        writer.writeheader()
        writer.writerows(rows)


class WUPImportTests(unittest.TestCase):
    def test_country_counts_and_transboundary_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "fixture.csv.gz"
            write_source(source, [
                make_row(),
                make_row(ISO2_Code="BY", ISO3_Code="BLR", Location="Beland", LocID="2", City_Code="10", City_Name="A-City East"),
                make_row(City_Code="11", City_Name="Second"),
                make_row(Year="2024", TimeMid="2024.5", City_Code="11"),
            ])
            baseline = root / "baseline.csv"
            baseline.write_text("iso2,name_en,name_ru\nAX,Aland,Aland\nBY,Beland,Beland\nCZ,Celand,Celand\n", encoding="utf-8")
            audit = build(source, root / "output", baseline)
            self.assertEqual(audit["rows_2025"], 3)
            self.assertEqual(audit["distinct_city_codes_2025"], 2)
            self.assertEqual(audit["transboundary_city_codes_2025"], {"10": ["AX", "BY"]})
            self.assertEqual(audit["global_sum_of_country_counts"], 3)
            self.assertEqual(audit["baseline_195"]["baseline_without_wup_city_rows"], ["CZ"])
            with closing(sqlite3.connect(root / "output" / "wup2025_2025.sqlite")) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM city_2025").fetchone()[0], 3)
                self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_duplicate_city_country_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.csv.gz"
            write_source(source, [make_row(), make_row()])
            with self.assertRaisesRegex(ValueError, "duplicate City_Code/ISO2_Code"):
                load_2025(source)

    def test_missing_city_code_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.csv.gz"
            write_source(source, [make_row(City_Code="")])
            with self.assertRaisesRegex(ValueError, "missing City_Code"):
                load_2025(source)

    def test_hash_pin_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "fixture.csv.gz"
            write_source(source, [make_row()])
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                build(source, root / "output", expected_sha256="0" * 64)


if __name__ == "__main__":
    unittest.main()
