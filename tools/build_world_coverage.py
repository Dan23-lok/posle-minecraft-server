"""Build an honest country-by-country Earth coverage register.

This reads the pinned Natural Earth join.  It never infers that source geometry
has been generated in Minecraft.  A separate Moscow staging pilot is recorded
only as staging evidence, not as main-world coverage.
"""

import csv
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "geodata" / "reference"
JOIN = REFERENCE / "natural_earth_country_join.csv"
JOIN_MANIFEST = REFERENCE / "natural_earth_join_manifest.json"
OUT = ROOT / "geodata" / "WORLD_COVERAGE.csv"


def main():
    manifest = json.loads(JOIN_MANIFEST.read_text(encoding="utf-8"))
    actual_hash = hashlib.sha256(JOIN.read_bytes()).hexdigest()
    if actual_hash != manifest["output_sha256"]:
        raise ValueError("Natural Earth country join differs from the pinned manifest")

    with JOIN.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 195 or len({row["iso2"] for row in rows}) != 195:
        raise ValueError("Expected 195 unique country rows")
    if {row["minecraft_terrain_generated"] for row in rows} != {"false"}:
        raise ValueError("Reference claim changed: inspect the generated world before updating")
    if {row["minecraft_spawn_validated"] for row in rows} != {"false"}:
        raise ValueError("Reference claim changed: inspect the game before updating")

    fields = [
        "iso2", "name_en", "source_polygon_status", "natural_earth_feature_index",
        "natural_earth_polygon_count", "natural_earth_join_method",
        "main_earth_terrain_status", "main_country_spawn_status",
        "isolated_staging_status", "evidence",
    ]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            if int(row["polygon_count"]) < 1:
                raise ValueError(f"No source polygon for {row['iso2']}")
            writer.writerow({
                "iso2": row["iso2"],
                "name_en": row["name_en"],
                "source_polygon_status": "source_polygon_only",
                "natural_earth_feature_index": row["natural_earth_feature_index"],
                "natural_earth_polygon_count": row["polygon_count"],
                "natural_earth_join_method": row["join_method"],
                "main_earth_terrain_status": "not_generated",
                "main_country_spawn_status": "not_validated",
                "isolated_staging_status": (
                    "moscow_cheremushki_pilot_only" if row["iso2"] == "RU" else "none"
                ),
                "evidence": (
                    "geodata/MOSCOW_STAGE.md" if row["iso2"] == "RU" else ""
                ),
            })
    print(f"Wrote {len(rows)} countries to {OUT}")


if __name__ == "__main__":
    main()
