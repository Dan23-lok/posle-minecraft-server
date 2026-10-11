#!/usr/bin/env python3
"""Extract *reference lists*, not game-world coverage, from the owner's two texts.

Only Python's standard library is required. The source files are supplied through
CLI arguments so published output never contains a private machine path.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import sys
from collections import Counter
from pathlib import Path


COUNTRY_START = "COUNTRY CHECKLIST — ALL 195 BASELINE ENTRIES"
COUNTRY_END = "The country CSV/JSON retains original source-place fields and qualifications."
AREA_START = "ПРИЛОЖЕНИЕ В. ДОПОЛНИТЕЛЬНЫЕ ГЕОГРАФИЧЕСКИЕ ЗАПИСИ"
AREA_END = "ИСТОЧНИКИ И ПРЕДЕЛЫ ПРОВЕРКИ"
REGIONS = {"Africa", "Americas", "Asia", "Europe", "Oceania"}
STATUSES = {"member_state", "observer_state"}
FLAGS = {
    "listed_in_registry": True,
    "geometry_loaded": False,
    "terrain_generated": False,
    "spawn_validated": False,
}


def section(text: str, start: str, end: str) -> tuple[str, int]:
    """Return a uniquely delimited section and its starting line number."""
    if text.count(start) != 1:
        raise ValueError(f"section marker must occur once: {start}")
    before, _, remainder = text.partition(start)
    if end not in remainder:
        raise ValueError(f"section end missing: {end}")
    body, _, _ = remainder.partition(end)
    return body, before.count("\n") + start.count("\n") + 1


def parse_countries(text: str) -> list[dict]:
    body, first_line = section(text, COUNTRY_START, COUNTRY_END)
    rows = []
    seen: set[str] = set()
    for index, line in enumerate(body.splitlines(), start=first_line):
        if not re.match(r"^[A-Z]{2} \|", line):
            continue
        parts = line.split(" | ")
        if len(parts) != 6 or any(not part for part in parts):
            raise ValueError(f"malformed country row at line {index}")
        iso2, english, russian, status, region, locality = parts
        if iso2 in seen:
            raise ValueError(f"duplicate country code: {iso2}")
        if status not in STATUSES or region not in REGIONS:
            raise ValueError(f"invalid country status/region for {iso2}")
        seen.add(iso2)
        rows.append(
            {
                "iso2": iso2,
                "name_en": english,
                "name_ru": russian,
                "un_status": status,
                "m49_broad_region": region,
                "reference_locality": locality,
                "source_line": index,
                "source_settlement_count": None,
                "wup_urban_centre_count": None,
                **FLAGS,
            }
        )
    return rows


def parse_areas(text: str) -> tuple[list[dict], dict]:
    body, first_line = section(text, AREA_START, AREA_END)
    areas = []
    xk = None
    seen: set[str] = set()
    for index, line in enumerate(body.splitlines(), start=first_line):
        if not re.match(r"^[A-Z]{2}:", line):
            continue
        match = re.fullmatch(r"([A-Z]{2}): (.+?) / (.+)", line)
        if match is None:
            raise ValueError(f"malformed area row at line {index}")
        code, russian, english = match.groups()
        if code in seen:
            raise ValueError(f"duplicate area code: {code}")
        seen.add(code)
        row = {
            "code": code,
            "name_en": english,
            "name_ru": russian,
            "catalog_kind": "geonames_extra_code" if code == "XK" else "iso_area_outside_195",
            "source_line": index,
            **FLAGS,
        }
        if code == "XK":
            xk = row
        else:
            areas.append(row)
    if xk is None:
        raise ValueError("GeoNames XK note missing")
    return areas, xk


def validate(countries: list[dict], areas: list[dict], xk: dict) -> None:
    statuses = Counter(row["un_status"] for row in countries)
    regions = Counter(row["m49_broad_region"] for row in countries)
    if len(countries) != 195 or statuses != {"member_state": 193, "observer_state": 2}:
        raise ValueError(f"country baseline scope mismatch: {len(countries)}, {dict(statuses)}")
    if regions != {"Africa": 54, "Americas": 35, "Asia": 48, "Europe": 44, "Oceania": 14}:
        raise ValueError(f"M49 broad-region scope mismatch: {dict(regions)}")
    if len(areas) != 54 or xk["code"] != "XK":
        raise ValueError(f"extra geographic code scope mismatch: {len(areas)} areas")
    country_codes = {row["iso2"] for row in countries}
    area_codes = {row["code"] for row in areas}
    if len(country_codes) != 195 or len(area_codes) != 54:
        raise ValueError("duplicate registry code")
    if country_codes & area_codes or "XK" in country_codes | area_codes:
        raise ValueError("baseline/area/XK code overlap")


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def csv_bytes(rows: list[dict], columns: list[str]) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow({key: ("true" if value else "false") if isinstance(value, bool)
                         else ("" if value is None else value)
                         for key, value in row.items()})
    return buffer.getvalue().encode("utf-8")


def source_description(path: Path, raw: bytes, section_name: str) -> dict:
    return {
        "file": path.name,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "encoding": "UTF-8",
        "provenance": "owner-supplied text",
        "extracted_section": section_name,
    }


def extract(en_path: Path, ru_path: Path, out: Path) -> dict:
    en_bytes = en_path.read_bytes()
    ru_bytes = ru_path.read_bytes()
    en_text = en_bytes.decode("utf-8-sig")
    ru_text = ru_bytes.decode("utf-8-sig")
    countries = parse_countries(en_text)
    areas, xk = parse_areas(ru_text)
    validate(countries, areas, xk)

    country_columns = [
        "iso2", "name_en", "name_ru", "un_status", "m49_broad_region",
        "reference_locality", "source_line", "source_settlement_count",
        "wup_urban_centre_count", *FLAGS,
    ]
    area_columns = ["code", "name_en", "name_ru", "catalog_kind", "source_line", *FLAGS]
    files = {
        "countries_195_reference.csv": csv_bytes(countries, country_columns),
        "countries_195_reference.json": json_bytes(countries),
        "areas_outside_195_baseline.csv": csv_bytes(areas, area_columns),
        "areas_outside_195_baseline.json": json_bytes(areas),
        "geonames_xk_note.json": json_bytes(xk),
    }
    manifest = {
        "schema_version": 1,
        "scope": "Text-derived reference catalogue only; no geographic geometry or Minecraft world coverage.",
        "counts": {
            "baseline_states": len(countries),
            "un_member_states": 193,
            "un_observer_states": 2,
            "iso_areas_outside_baseline": len(areas),
            "geonames_extra_codes": 1,
        },
        "sources": [
            source_description(en_path, en_bytes, COUNTRY_START),
            source_description(ru_path, ru_bytes, AREA_START),
        ],
        "outputs": [
            {"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in sorted(files.items())
        ],
        "limitations": [
            "The 195-country convention is 193 UN members plus two observer states as written in the supplied text; this extractor does not revalidate current UN status.",
            "M49 broad region is a statistical label, not physical extent of a transcontinental country.",
            "Reference localities are illustrative, not a certified current list of capitals.",
            "Additional ISO areas and GeoNames XK are separate from the 195-state baseline; no sovereignty conclusion is drawn.",
            "No country/area polygons, settlement catalogue, city counts, generated Minecraft terrain, or safe spawn checks are supplied by these source texts.",
        ],
    }
    files["manifest.json"] = json_bytes(manifest)
    out.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (out / name).write_bytes(data)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--en-source", required=True, type=Path)
    parser.add_argument("--ru-source", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        manifest = extract(args.en_source, args.ru_source, args.out)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"reference catalogue extraction failed: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(manifest["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
