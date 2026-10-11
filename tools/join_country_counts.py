"""Join pinned GeoNames settlement counts with UN WUP 2025 urban-centre counts.

Both columns describe source data, never completed Minecraft cities. The
original GeoNames report remains unchanged for provenance.
"""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GEO = ROOT / "geodata/reports/geonames-2026-10-10-v3/countries_195_geonames_counts.csv"
WUP = ROOT / "geodata/reports/wup2025-un-2026-10-11/baseline_195_wup2025_counts.csv"
OUT = ROOT / "geodata/reports/country-counts-195-2026-10-11"
PINNED_SHA256 = {
    "geonames": "22885e4d2dbfa6b3d07372172337e47f105a14b40173862d8bf4a5ac4a7fdcc9",
    "wup": "f1ac6bda7c8398d0decc87701a137adb6d07a1e2bf9b04b8649b7cc34b600671",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _unique(rows: list[dict[str, str]], key: str) -> dict[str, dict[str, str]]:
    output: dict[str, dict[str, str]] = {}
    for row in rows:
        code = row[key]
        if len(code) != 2 or not code.isascii() or not code.isupper():
            raise ValueError(f"invalid ISO code: {code!r}")
        if code in output:
            raise ValueError(f"duplicate ISO code: {code}")
        output[code] = row
    return output


def join_counts(
    geonames: list[dict[str, str]], wup: list[dict[str, str]], expected_rows: int = 195
) -> list[dict[str, str]]:
    geo_by_iso = _unique(geonames, "code")
    wup_by_iso = _unique(wup, "iso2")
    if set(geo_by_iso) != set(wup_by_iso):
        raise ValueError("ISO set mismatch between GeoNames and WUP baseline")
    if len(geo_by_iso) != expected_rows or len(wup_by_iso) != expected_rows:
        raise ValueError(f"expected {expected_rows} rows in each source")

    output = []
    for geo in geonames:
        wup_row = wup_by_iso[geo["code"]]
        count = int(wup_row["wup_urban_centres_2025"])
        observed = wup_row["observed_in_wup_city_rows_2025"]
        if count < 0 or observed not in {"true", "false"} or (count > 0) != (observed == "true"):
            raise ValueError(f"observation/count mismatch for {geo['code']}")
        if geo["wup_2025_urban_centre_count"] or geo["wup_count_status"] != "NOT_IMPORTED":
            raise ValueError(f"GeoNames report WUP fields already changed for {geo['code']}")
        joined = dict(geo)
        joined["wup_2025_urban_centre_count"] = str(count)
        joined["wup_count_status"] = "COUNTED_IN_UN_WUP2025_SOURCE"
        joined["wup_city_rows_observed"] = observed
        output.append(joined)
    return output


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        return list(csv.DictReader(source))


def main() -> None:
    for label, path in (("geonames", GEO), ("wup", WUP)):
        if sha256(path) != PINNED_SHA256[label]:
            raise ValueError(f"{label} input SHA256 changed: {path}")
    rows = join_counts(read_csv(GEO), read_csv(WUP))
    OUT.mkdir(parents=True, exist_ok=True)
    csv_path = OUT / "countries_195_geonames_wup2025_counts.csv"
    columns = list(rows[0])
    with csv_path.open("w", encoding="utf-8", newline="") as target:
        writer = csv.DictWriter(target, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    manifest = {
        "geonames_input_sha256": PINNED_SHA256["geonames"],
        "wup_input_sha256": PINNED_SHA256["wup"],
        "output_sha256": sha256(csv_path),
        "countries": len(rows),
        "geonames_selected_settlement_rows": sum(int(row["source_settlement_count"]) for row in rows),
        "wup_urban_centres_in_195": sum(int(row["wup_2025_urban_centre_count"]) for row in rows),
        "wup_zero_row_countries": [row["code"] for row in rows if row["wup_city_rows_observed"] == "false"],
        "game_status": "not generated or verified by this data join",
    }
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    main()
