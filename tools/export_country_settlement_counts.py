"""Export pinned GeoNames settlement counts, separate from UN WUP city counts."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


SETTLEMENT_CODES = frozenset(
    ("PPL", "PPLA", "PPLA2", "PPLA3", "PPLA4", "PPLA5", "PPLC", "PPLL")
)
FIELDS = (
    "code", "name_en", "name_ru", "catalog_kind", "m49_broad_region",
    "source_settlement_count", "source_count_status",
    "wup_2025_urban_centre_count", "wup_count_status",
    "minecraft_terrain_status", "minecraft_spawn_status",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream))


def build_rows(countries, areas, counts):
    baseline_codes = [row["iso2"] for row in countries]
    if len(baseline_codes) != len(set(baseline_codes)):
        raise ValueError("duplicate baseline code")
    area_codes = [row["code"] for row in areas]
    if len(area_codes) != len(set(area_codes)) or set(area_codes) & set(baseline_codes):
        raise ValueError("duplicate or overlapping area code")

    totals = defaultdict(int)
    seen_pairs = set()
    for row in counts:
        pair = (row["country_code"], row["feature_code"])
        if pair in seen_pairs:
            raise ValueError(f"duplicate country/feature pair: {pair}")
        seen_pairs.add(pair)
        amount = int(row["populated_place_source_records"])
        if amount < 0:
            raise ValueError(f"negative source count: {pair}")
        if pair[1] in SETTLEMENT_CODES:
            totals[pair[0]] += amount

    def result(code: str, name_en: str, name_ru: str, kind: str, region: str) -> dict:
        amount = totals.get(code, 0)
        return {
            "code": code,
            "name_en": name_en,
            "name_ru": name_ru,
            "catalog_kind": kind,
            "m49_broad_region": region,
            "source_settlement_count": amount,
            "source_count_status": "COUNTED_IN_PINNED_GEONAMES" if amount else "OBSERVED_ZERO_IN_SOURCE",
            "wup_2025_urban_centre_count": "",
            "wup_count_status": "NOT_IMPORTED",
            "minecraft_terrain_status": "NOT_GENERATED",
            "minecraft_spawn_status": "NOT_VALIDATED",
        }

    country_rows = [
        result(row["iso2"], row["name_en"], row["name_ru"], row["un_status"], row["m49_broad_region"])
        for row in countries
    ]
    area_rows = [
        result(row["code"], row["name_en"], row["name_ru"], row["catalog_kind"], "")
        for row in areas
    ]
    baseline_total = sum(row["source_settlement_count"] for row in country_rows)
    area_total = sum(row["source_settlement_count"] for row in area_rows)
    all_total = sum(totals.values())
    classified_codes = set(baseline_codes) | set(area_codes)
    other_by_code = {code: totals[code] for code in sorted(totals) if code not in classified_codes}
    return country_rows, area_rows, {
        "selected_source_rows": all_total,
        "baseline_rows": baseline_total,
        "area_rows": area_total,
        "other_or_unassigned_rows": all_total - baseline_total - area_total,
        "other_by_code": other_by_code,
    }


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-dir", type=Path, required=True)
    parser.add_argument("--catalogue-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source_csv = args.catalogue_dir / "populated_places_by_country_and_code.csv"
    source_manifest = json.loads((args.catalogue_dir / "catalogue_manifest.json").read_text(encoding="utf-8"))
    expected_csv = source_manifest["country_feature_count_export"]
    if sha256(source_csv) != expected_csv["sha256"]:
        raise ValueError("Pinned country/code count CSV SHA-256 mismatch")
    counts = read_csv(source_csv)
    if len(counts) != expected_csv["rows"]:
        raise ValueError("Pinned country/code CSV row count mismatch")
    countries = read_csv(args.reference_dir / "countries_195_reference.csv")
    areas = read_csv(args.reference_dir / "areas_outside_195_baseline.csv")
    if (len(countries), len(areas)) != (195, 54):
        raise ValueError("Expected 195 baseline countries and 54 extra ISO areas")
    if sum(row["un_status"] == "member_state" for row in countries) != 193:
        raise ValueError("Expected 193 UN members in adopted baseline")
    if sum(row["un_status"] == "observer_state" for row in countries) != 2:
        raise ValueError("Expected 2 UN observers in adopted baseline")
    country_rows, area_rows, summary = build_rows(countries, areas, counts)
    if summary["selected_source_rows"] != source_manifest["counts"]["current_candidate_settlement_rows"]:
        raise ValueError("Selected code sum disagrees with full SQLite import")
    args.out.mkdir(parents=True, exist_ok=True)
    country_output = args.out / "countries_195_geonames_counts.csv"
    area_output = args.out / "areas_54_geonames_counts.csv"
    other_output = args.out / "other_geonames_codes.csv"
    write_csv(country_output, country_rows)
    write_csv(area_output, area_rows)
    with other_output.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("source_country_code", "source_settlement_count", "classification"))
        for code, amount in summary["other_by_code"].items():
            writer.writerow((code, amount, "OUTSIDE_ADOPTED_COUNTRY_AND_ISO_AREA_LIST" if code else "MISSING_SOURCE_COUNTRY_CODE"))
    manifest = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_provider": "GeoNames",
        "source_snapshot": "2026-10-10-v3",
        "source_catalogue_sha256": source_manifest["database"]["sha256"],
        "source_count_csv_sha256": expected_csv["sha256"],
        "count_definition": "GeoNames P-class source rows with exactly the selected feature codes; this is not a count of legal cities or WUP urban centres.",
        "selected_feature_codes": sorted(SETTLEMENT_CODES),
        "summary": summary,
        "files": {
            country_output.name: {"rows": len(country_rows), "bytes": country_output.stat().st_size, "sha256": sha256(country_output)},
            area_output.name: {"rows": len(area_rows), "bytes": area_output.stat().st_size, "sha256": sha256(area_output)},
            other_output.name: {"rows": len(summary["other_by_code"]), "bytes": other_output.stat().st_size, "sha256": sha256(other_output)},
        },
        "wup_2025_status": "NOT_IMPORTED",
        "minecraft_terrain_status": "NOT_GENERATED",
        "minecraft_spawn_status": "NOT_VALIDATED",
        "license": "GeoNames CC BY 4.0; country names/status from owner reference registry; attribution retained.",
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"countries": len(country_rows), "areas": len(area_rows), **summary}, ensure_ascii=False))


if __name__ == "__main__":
    main()
