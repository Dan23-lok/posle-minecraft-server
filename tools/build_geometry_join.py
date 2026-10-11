"""Audit the 195-country checklist against pinned Natural Earth geometry.

The join is geographic source coverage, not Minecraft world coverage. The
Natural Earth Admin-0 layer contains 258 features with a different political
classification from the owner's 195-entry UN-based checklist.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path


EXPLICIT_FALLBACKS = {"FR": ("ADM0_A3", "FRA"), "NO": ("ADM0_A3", "NOR")}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_source(raw: Path, name: str, manifest: dict) -> dict:
    item = manifest["files"][name]
    path = raw / name
    if path.stat().st_size != item["bytes"] or sha256_file(path) != item["sha256"]:
        raise ValueError(f"Natural Earth source hash mismatch: {name}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("type") != "FeatureCollection" or not isinstance(data.get("features"), list):
        raise ValueError(f"Not a GeoJSON FeatureCollection: {name}")
    return data


def find_match(iso2: str, features: list[dict]) -> tuple[int, str]:
    direct = [i for i, feature in enumerate(features) if feature["properties"].get("ISO_A2") == iso2]
    if len(direct) == 1:
        return direct[0], "ISO_A2"
    if len(direct) > 1:
        raise ValueError(f"Ambiguous ISO_A2 for {iso2}: {direct}")
    if iso2 not in EXPLICIT_FALLBACKS:
        raise ValueError(f"No verified geometry match for {iso2}")
    field, value = EXPLICIT_FALLBACKS[iso2]
    fallback = [i for i, feature in enumerate(features) if feature["properties"].get(field) == value]
    if len(fallback) != 1:
        raise ValueError(f"Ambiguous/missing explicit {field}={value} for {iso2}: {fallback}")
    return fallback[0], f"{field}={value}"


def polygon_parts(geometry: dict) -> list[list[list[list[float]]]]:
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return geometry["coordinates"]
    raise ValueError(f"Unexpected country geometry type: {geometry['type']}")


def geometry_summary(geometry: dict) -> tuple[int, int, str]:
    polygons = polygon_parts(geometry)
    rings = sum(len(polygon) for polygon in polygons)
    vertices = sum(len(ring) for polygon in polygons for ring in polygon)
    for polygon in polygons:
        for ring in polygon:
            for point in ring:
                if len(point) < 2 or not (-180 <= point[0] <= 180 and -90 <= point[1] <= 90):
                    raise ValueError("Invalid longitude/latitude in source geometry")
    return len(polygons), rings, str(vertices)


def build(raw: Path, countries_csv: Path, output: Path) -> dict:
    manifest = json.loads((raw / "source_manifest.json").read_text(encoding="utf-8"))
    if manifest.get("provider") != "Natural Earth" or manifest.get("version") != "5.1.1":
        raise ValueError("Expected pinned Natural Earth 5.1.1 manifest")
    countries = verify_source(raw, "ne_10m_admin_0_countries.geojson", manifest)["features"]
    land = verify_source(raw, "ne_10m_land.geojson", manifest)["features"]
    with countries_csv.open(encoding="utf-8", newline="") as handle:
        baseline = list(csv.DictReader(handle))
    if len(baseline) != 195 or len({row["iso2"] for row in baseline}) != 195:
        raise ValueError("Baseline is not the owner's 195 unique entries")
    rows = []
    for row in baseline:
        index, method = find_match(row["iso2"], countries)
        feature = countries[index]
        polygon_count, ring_count, vertex_count = geometry_summary(feature["geometry"])
        rows.append({
            "iso2": row["iso2"], "name_en": row["name_en"],
            "natural_earth_feature_index": index, "natural_earth_name": feature["properties"].get("NAME", ""),
            "join_method": method, "polygon_count": polygon_count,
            "ring_count": ring_count, "vertex_count": vertex_count,
            "minecraft_terrain_generated": "false", "minecraft_spawn_validated": "false",
        })
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    result = {
        "baseline_rows": len(rows), "natural_earth_country_features": len(countries),
        "natural_earth_land_features": len(land),
        "direct_iso_a2_matches": sum(row["join_method"] == "ISO_A2" for row in rows),
        "explicit_fallback_matches": sum(row["join_method"] != "ISO_A2" for row in rows),
        "source_manifest_sha256": sha256_file(raw / "source_manifest.json"),
        "output": output.name, "output_sha256": sha256_file(output),
        "scope": "Natural Earth generalized boundary feature join only; no Minecraft world validation.",
    }
    (output.parent / "natural_earth_join_manifest.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8"
    )
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.raw, args.baseline, args.out), indent=2, ensure_ascii=False))
