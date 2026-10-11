"""Import the official UN WUP 2025 city CSV.gz without touching Minecraft worlds.

The exact CSV.gz is retained.  The derived SQLite and CSVs contain one row per
UN City_Code/ISO2_Code record at Year=2025.  Country totals count distinct
City_Code values within each country.  A centre spanning multiple country rows
would count once in each country and once globally; such codes are audited.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import math
import sqlite3
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

SOURCE_URL = (
    "https://population.un.org/wup/assets/Download/Cities/"
    "WUP2025-DB-DEGURBA-Cities-Population-Surface-Data.csv.gz"
)
OFFICIAL_DOWNLOADS_URL = "https://population.un.org/wup/downloads?tab=Cities"
LICENSE_REFERENCE_URL = "https://population.un.org/wup/faqs"
REQUIRED = (
    "LocID", "Location", "ISO3_Code", "ISO2_Code", "City_Code",
    "City_Name", "Year", "PWCent_Latitude", "PWCent_Longitude", "Pop",
    "TimeMid", "Pop_plausibility", "AREA_km2", "BU_km2",
)
SELECTED_COLUMNS = (
    "City_Code", "City_Name", "LocID", "Location", "ISO3_Code",
    "ISO2_Code", "Year", "TimeMid", "PWCent_Latitude",
    "PWCent_Longitude", "Pop", "Pop_plausibility", "AREA_km2",
    "BU_km2", "Capital", "Notes",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for part in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(part)
    return digest.hexdigest()


def _validate_city(row: dict[str, str], line_number: int) -> None:
    for key in REQUIRED:
        if not row.get(key):
            raise ValueError(f"line {line_number}: missing {key}")
    if len(row["ISO2_Code"]) != 2 or not row["ISO2_Code"].isupper():
        raise ValueError(f"line {line_number}: invalid ISO2_Code")
    if row["TimeMid"] != "2025.5":
        raise ValueError(f"line {line_number}: unexpected TimeMid {row['TimeMid']}")
    lat = float(row["PWCent_Latitude"])
    lon = float(row["PWCent_Longitude"])
    pop = float(row["Pop"])
    if not all(map(math.isfinite, (lat, lon, pop))):
        raise ValueError(f"line {line_number}: non-finite location/population")
    if not (-90 <= lat <= 90 and -180 <= lon <= 180 and pop > 0):
        raise ValueError(f"line {line_number}: out-of-range location/population")


def load_2025(source: Path) -> tuple[list[dict[str, str]], dict]:
    year_counts: Counter[str] = Counter()
    centres: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    city_to_countries: dict[str, set[str]] = defaultdict(set)
    iso_to_names: dict[str, set[str]] = defaultdict(set)
    below_50k: list[dict[str, str]] = []
    with gzip.open(source, "rt", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        columns = reader.fieldnames or []
        missing_columns = sorted(set(REQUIRED) - set(columns))
        if missing_columns:
            raise ValueError(f"missing source columns: {missing_columns}")
        for line_number, row in enumerate(reader, start=2):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"line {line_number}: invalid CSV field count")
            year = row["Year"]
            if not year.isdecimal():
                raise ValueError(f"line {line_number}: invalid year {year!r}")
            year_counts[year] += 1
            if year != "2025":
                continue
            _validate_city(row, line_number)
            key = (row["City_Code"], row["ISO2_Code"])
            if key in seen:
                raise ValueError(f"line {line_number}: duplicate City_Code/ISO2_Code {key}")
            seen.add(key)
            city_to_countries[row["City_Code"]].add(row["ISO2_Code"])
            iso_to_names[row["ISO2_Code"]].add(row["Location"])
            if float(row["Pop"]) < 50:
                below_50k.append({
                    "city_code": row["City_Code"],
                    "city_name": row["City_Name"],
                    "iso2": row["ISO2_Code"],
                    "pop_thousands": row["Pop"],
                })
            centres.append(row)

    if not centres:
        raise ValueError("source contains no 2025 city rows")
    inconsistent_names = {
        iso: sorted(names) for iso, names in iso_to_names.items() if len(names) > 1
    }
    if inconsistent_names:
        raise ValueError(f"inconsistent country names: {inconsistent_names}")
    centres.sort(key=lambda row: (row["ISO2_Code"], int(row["City_Code"])))
    transboundary = {
        code: sorted(countries)
        for code, countries in city_to_countries.items() if len(countries) > 1
    }
    audit = {
        "source_columns": columns,
        "all_year_row_count": sum(year_counts.values()),
        "year_min": min(map(int, year_counts)),
        "year_max": max(map(int, year_counts)),
        "year_counts": dict(sorted(year_counts.items(), key=lambda item: int(item[0]))),
        "rows_2025": len(centres),
        "distinct_city_codes_2025": len(city_to_countries),
        "distinct_country_codes_2025": len(iso_to_names),
        "country_names_by_iso2": {
            iso: next(iter(names)) for iso, names in sorted(iso_to_names.items())
        },
        "transboundary_city_codes_2025": transboundary,
        "below_50k_midyear_rows_2025": below_50k,
    }
    return centres, audit


def country_counts(centres: list[dict[str, str]]) -> list[dict[str, str | int]]:
    city_codes: dict[str, set[str]] = defaultdict(set)
    countries: dict[str, tuple[str, str, str]] = {}
    for row in centres:
        iso = row["ISO2_Code"]
        city_codes[iso].add(row["City_Code"])
        identity = (row["ISO3_Code"], row["LocID"], row["Location"])
        if iso in countries and countries[iso] != identity:
            raise ValueError(f"country metadata changed within ISO2 {iso}")
        countries[iso] = identity
    return [
        {
            "ISO2_Code": iso,
            "ISO3_Code": countries[iso][0],
            "LocID": countries[iso][1],
            "Location": countries[iso][2],
            "urban_centres_2025": len(city_codes[iso]),
        }
        for iso in sorted(city_codes)
    ]


def baseline_counts(
    baseline_path: Path, country_rows: list[dict[str, str | int]]
) -> tuple[list[dict[str, str | int]], dict]:
    by_iso = {str(row["ISO2_Code"]): row for row in country_rows}
    output = []
    seen = set()
    with baseline_path.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            iso = row["iso2"]
            if iso in seen:
                raise ValueError(f"baseline has duplicate ISO2 {iso}")
            seen.add(iso)
            matched = by_iso.get(iso)
            output.append({
                "iso2": iso,
                "name_en": row["name_en"],
                "name_ru": row["name_ru"],
                "wup_urban_centres_2025": int(matched["urban_centres_2025"]) if matched else 0,
                "observed_in_wup_city_rows_2025": "true" if matched else "false",
            })
    output.sort(key=lambda row: str(row["iso2"]))
    return output, {
        "baseline_rows": len(output),
        "baseline_with_wup_cities": sum(row["observed_in_wup_city_rows_2025"] == "true" for row in output),
        "baseline_without_wup_city_rows": [row["iso2"] for row in output if row["observed_in_wup_city_rows_2025"] == "false"],
        "wup_country_codes_outside_baseline": sorted(set(by_iso) - seen),
    }


def _write_csv(path: Path, columns: tuple[str, ...], rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def _write_sqlite(path: Path, centres: list[dict[str, str]], audit: dict) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("PRAGMA synchronous=FULL")
        connection.executescript("""
            CREATE TABLE city_2025 (
              city_code TEXT NOT NULL,
              iso2_code TEXT NOT NULL,
              iso3_code TEXT NOT NULL,
              locid INTEGER NOT NULL,
              location TEXT NOT NULL,
              city_name TEXT NOT NULL,
              latitude REAL NOT NULL,
              longitude REAL NOT NULL,
              population_thousands REAL NOT NULL,
              population_plausibility TEXT NOT NULL,
              area_km2 REAL NOT NULL,
              builtup_area_km2 REAL NOT NULL,
              capital TEXT,
              source_row_json TEXT NOT NULL,
              PRIMARY KEY (city_code, iso2_code)
            );
            CREATE INDEX city_2025_country_idx ON city_2025 (iso2_code, city_name);
            CREATE INDEX city_2025_name_idx ON city_2025 (city_name);
            CREATE TABLE provenance (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        connection.executemany(
            "INSERT INTO city_2025 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                (
                    row["City_Code"], row["ISO2_Code"], row["ISO3_Code"],
                    int(row["LocID"]), row["Location"], row["City_Name"],
                    float(row["PWCent_Latitude"]), float(row["PWCent_Longitude"]),
                    float(row["Pop"]), row["Pop_plausibility"],
                    float(row["AREA_km2"]), float(row["BU_km2"]),
                    row["Capital"], json.dumps(row, ensure_ascii=False, sort_keys=True),
                )
                for row in centres
            ],
        )
        connection.executemany(
            "INSERT INTO provenance VALUES (?,?)",
            [(key, json.dumps(value, ensure_ascii=False, sort_keys=True))
             for key, value in audit.items() if key != "country_names_by_iso2"],
        )
        connection.commit()
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("SQLite integrity_check failed")
    finally:
        connection.close()


def build(
    source: Path,
    output_dir: Path,
    baseline_path: Path | None = None,
    expected_sha256: str | None = None,
) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    digest = sha256_file(source)
    if expected_sha256 and digest.lower() != expected_sha256.lower():
        raise ValueError(f"SHA256 mismatch: {digest}")
    centres, audit = load_2025(source)
    country_rows = country_counts(centres)
    audit.update({
        "source_url": SOURCE_URL,
        "official_downloads_url": OFFICIAL_DOWNLOADS_URL,
        "license": "CC BY 3.0 IGO (UN WUP 2025 FAQ)",
        "license_reference_url": LICENSE_REFERENCE_URL,
        "source_filename": source.name,
        "source_bytes": source.stat().st_size,
        "source_sha256": digest,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "count_definition": "distinct City_Code among UN source rows with Year=2025, within ISO2_Code",
        "global_sum_of_country_counts": sum(int(r["urban_centres_2025"]) for r in country_rows),
    })
    if baseline_path:
        baseline_rows, baseline_audit = baseline_counts(baseline_path, country_rows)
        audit["baseline_195"] = baseline_audit
        _write_csv(
            output_dir / "baseline_195_wup2025_counts.csv",
            ("iso2", "name_en", "name_ru", "wup_urban_centres_2025", "observed_in_wup_city_rows_2025"),
            baseline_rows,
        )
    _write_csv(output_dir / "urban_centres_2025.csv", SELECTED_COLUMNS, centres)
    _write_csv(
        output_dir / "urban_centres_2025_by_country.csv",
        ("ISO2_Code", "ISO3_Code", "LocID", "Location", "urban_centres_2025"),
        country_rows,
    )
    _write_sqlite(output_dir / "wup2025_2025.sqlite", centres, audit)
    (output_dir / "audit.json").write_text(
        json.dumps(audit, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    return audit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--baseline-195", type=Path)
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    audit = build(args.source, args.output_dir, args.baseline_195, args.expected_sha256)
    print(json.dumps({key: audit[key] for key in (
        "source_sha256", "rows_2025", "distinct_city_codes_2025",
        "distinct_country_codes_2025", "global_sum_of_country_counts",
    )}, ensure_ascii=False))


if __name__ == "__main__":
    main()
