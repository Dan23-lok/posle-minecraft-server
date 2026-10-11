"""Import a pinned full GeoNames dump into a searchable SQLite catalogue.

The raw files remain unchanged. A completed database is published only after all
rows have been read, validated, counted, indexed and checked. This catalogue is
real-world reference data, not a Minecraft world or a count of legal cities.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import sqlite3
import zipfile
from collections import Counter
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path


REQUIRED = (
    "allCountries.zip",
    "alternateNamesV2.zip",
    "admin1CodesASCII.txt",
    "admin2Codes.txt",
    "countryInfo.txt",
    "featureCodes_en.txt",
)
GEONAMES_FIELDS = (
    "geoname_id", "name", "ascii_name", "alternatenames_compact",
    "latitude", "longitude", "feature_class", "feature_code",
    "country_code", "alternate_country_codes", "admin1_code",
    "admin2_code", "admin3_code", "admin4_code", "population",
    "elevation", "dem", "timezone", "modification_date",
)
ALTERNATE_FIELDS = (
    "alternate_name_id", "geoname_id", "iso_language", "alternate_name",
    "is_preferred", "is_short", "is_colloquial", "is_historic",
    "from_period", "to_period",
)
COUNTRY_FIELDS = (
    "iso2", "iso3", "iso_numeric", "fips", "country_name", "capital",
    "area_sq_km", "population", "continent", "tld", "currency_code",
    "currency_name", "phone", "postal_format", "postal_regex", "languages",
    "geoname_id", "neighbours", "equivalent_fips_code",
)
BATCH_SIZE = 10_000
CHUNK_BYTES = 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for part in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(part)
    return digest.hexdigest()


def verify_raw(raw: Path) -> dict:
    manifest_path = raw / "source_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("provider") != "GeoNames":
        raise ValueError("Raw manifest is not GeoNames")
    for name in REQUIRED:
        entry = manifest.get("files", {}).get(name)
        path = raw / name
        if not entry or not path.is_file():
            raise ValueError(f"Missing pinned source file: {name}")
        if path.stat().st_size != entry["bytes"] or sha256_file(path) != entry["sha256"]:
            raise ValueError(f"Pinned source file failed SHA-256 check: {name}")
    return manifest


def strict_int(value: str, field: str, line: int, nullable: bool = False) -> int | None:
    if value == "" and nullable:
        return None
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"line {line}: invalid {field}: {value!r}") from exc


def parse_geoname(line: str, number: int) -> tuple:
    values = line.rstrip("\r\n").split("\t")
    if len(values) != len(GEONAMES_FIELDS):
        raise ValueError(f"line {number}: geoname has {len(values)} fields, expected 19")
    values[0] = strict_int(values[0], "geoname_id", number)
    for index, label, bounds in ((4, "latitude", (-90, 90)), (5, "longitude", (-180, 180))):
        try:
            coordinate = float(values[index])
        except ValueError as exc:
            raise ValueError(f"line {number}: invalid {label}") from exc
        if not bounds[0] <= coordinate <= bounds[1]:
            raise ValueError(f"line {number}: out-of-range {label}")
        values[index] = coordinate
    values[14] = strict_int(values[14], "population", number)
    values[15] = strict_int(values[15], "elevation", number, nullable=True)
    values[16] = strict_int(values[16], "dem", number, nullable=True)
    # The official dump contains blank class/code fields on real records.
    # Preserve these source blanks rather than inventing a classification.
    if not values[1]:
        raise ValueError(f"line {number}: geoname name missing")
    return tuple(values)


def parse_alternate(line: str, number: int) -> tuple:
    values = line.rstrip("\r\n").split("\t")
    if len(values) != len(ALTERNATE_FIELDS):
        raise ValueError(f"line {number}: alternate name has {len(values)} fields, expected 10")
    values[0] = strict_int(values[0], "alternate_name_id", number)
    values[1] = strict_int(values[1], "geoname_id", number)
    # Six rows in the pinned official dump have an empty alias field. Keep the
    # source record and expose the anomaly in the catalogue counts.
    return tuple(values)


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE TABLE geonames (
            geoname_id INTEGER PRIMARY KEY, name TEXT NOT NULL, ascii_name TEXT,
            alternatenames_compact TEXT, latitude REAL NOT NULL,
            longitude REAL NOT NULL, feature_class TEXT NOT NULL,
            feature_code TEXT NOT NULL, country_code TEXT,
            alternate_country_codes TEXT, admin1_code TEXT, admin2_code TEXT,
            admin3_code TEXT, admin4_code TEXT, population INTEGER NOT NULL,
            elevation INTEGER, dem INTEGER, timezone TEXT, modification_date TEXT
        );
        CREATE TABLE alternate_names (
            alternate_name_id INTEGER PRIMARY KEY, geoname_id INTEGER NOT NULL,
            iso_language TEXT, alternate_name TEXT NOT NULL, is_preferred TEXT,
            is_short TEXT, is_colloquial TEXT, is_historic TEXT,
            from_period TEXT, to_period TEXT
        );
        CREATE TABLE admin1 (code TEXT PRIMARY KEY, name TEXT, ascii_name TEXT, geoname_id TEXT);
        CREATE TABLE admin2 (code TEXT PRIMARY KEY, name TEXT, ascii_name TEXT, geoname_id TEXT);
        CREATE TABLE country_info (
            iso2 TEXT PRIMARY KEY, iso3 TEXT, iso_numeric TEXT, fips TEXT,
            country_name TEXT, capital TEXT, area_sq_km TEXT, population TEXT,
            continent TEXT, tld TEXT, currency_code TEXT, currency_name TEXT,
            phone TEXT, postal_format TEXT, postal_regex TEXT, languages TEXT,
            geoname_id TEXT, neighbours TEXT, equivalent_fips_code TEXT
        );
        CREATE TABLE feature_codes (code TEXT PRIMARY KEY, name TEXT, description TEXT);
        """
    )


def insert_batch(connection: sqlite3.Connection, table: str, rows: list[tuple]) -> None:
    placeholders = ",".join("?" for _ in rows[0])
    connection.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
    rows.clear()


def stream_zip_table(
    connection: sqlite3.Connection, archive: Path, member: str,
    table: str, fields: tuple[str, ...], parser,
) -> int:
    batch: list[tuple] = []
    count = 0
    with zipfile.ZipFile(archive) as zipped:
        if member not in zipped.namelist():
            raise ValueError(f"Missing ZIP member: {member}")
        with zipped.open(member) as binary, io.TextIOWrapper(binary, encoding="utf-8", newline="") as text:
            for number, line in enumerate(text, start=1):
                try:
                    batch.append(parser(line, number))
                    if len(batch) >= BATCH_SIZE:
                        insert_batch(connection, table, batch)
                        connection.commit()
                    count += 1
                    if count % 1_000_000 == 0:
                        print(f"{table}: read {count:,} source rows", flush=True)
                except (ValueError, sqlite3.IntegrityError) as exc:
                    raise ValueError(f"{archive.name}/{member}: {exc}") from exc
            if batch:
                try:
                    insert_batch(connection, table, batch)
                    connection.commit()
                except sqlite3.IntegrityError as exc:
                    raise ValueError(f"{archive.name}/{member}: duplicate ID near row {count}") from exc
    return count


def import_lookup(connection: sqlite3.Connection, path: Path, table: str, fields: int) -> int:
    batch: list[tuple] = []
    count = 0
    with path.open("r", encoding="utf-8", newline="") as handle:
        for number, line in enumerate(handle, start=1):
            if not line.strip() or line.startswith("#"):
                continue
            values = line.rstrip("\r\n").split("\t", maxsplit=fields - 1)
            if len(values) != fields:
                raise ValueError(f"{path.name} line {number}: {len(values)} fields, expected {fields}")
            batch.append(tuple(values))
            if len(batch) >= BATCH_SIZE:
                try:
                    insert_batch(connection, table, batch)
                    connection.commit()
                except sqlite3.IntegrityError as exc:
                    raise ValueError(f"{path.name} line {number}: duplicate lookup key") from exc
            count += 1
        if batch:
            try:
                insert_batch(connection, table, batch)
                connection.commit()
            except sqlite3.IntegrityError as exc:
                raise ValueError(f"{path.name}: duplicate lookup key") from exc
    return count


def finish_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE INDEX geonames_country_class_code ON geonames(country_code, feature_class, feature_code);
        CREATE INDEX geonames_admin_chain ON geonames(country_code, admin1_code, admin2_code, admin3_code, admin4_code);
        CREATE INDEX geonames_name ON geonames(name);
        CREATE INDEX alternate_geoname_language ON alternate_names(geoname_id, iso_language);
        CREATE INDEX alternate_language_name ON alternate_names(iso_language, alternate_name);
        CREATE VIEW populated_places AS
          SELECT g.*,
            (SELECT a.alternate_name FROM alternate_names a
             WHERE a.geoname_id = g.geoname_id AND a.iso_language = 'ru'
               AND COALESCE(a.is_historic, '') != '1'
             ORDER BY CASE WHEN a.is_preferred = '1' THEN 0 ELSE 1 END,
                      a.alternate_name_id LIMIT 1) AS russian_name_candidate
          FROM geonames g WHERE g.feature_class = 'P';
        CREATE VIEW current_candidate_settlements AS
          SELECT * FROM populated_places WHERE feature_code IN
            ('PPL','PPLA','PPLA2','PPLA3','PPLA4','PPLA5','PPLC','PPLL');
        CREATE VIEW populated_places_with_admin AS
          SELECT p.*, a1.name AS admin1_name, a2.name AS admin2_name
          FROM populated_places p
          LEFT JOIN admin1 a1 ON a1.code = p.country_code || '.' || p.admin1_code
          LEFT JOIN admin2 a2 ON a2.code = p.country_code || '.' || p.admin1_code || '.' || p.admin2_code;
        """
    )


def compute_counts(connection: sqlite3.Connection) -> dict[str, int]:
    def count(sql: str) -> int:
        return int(connection.execute(sql).fetchone()[0])

    return {
        "geonames_source_rows": count("SELECT COUNT(*) FROM geonames"),
        "alternate_name_source_rows": count("SELECT COUNT(*) FROM alternate_names"),
        "populated_place_source_rows": count("SELECT COUNT(*) FROM populated_places"),
        "current_candidate_settlement_rows": count("SELECT COUNT(*) FROM current_candidate_settlements"),
        "pplx_section_rows": count("SELECT COUNT(*) FROM populated_places WHERE feature_code='PPLX'"),
        "russian_alias_rows": count("SELECT COUNT(*) FROM alternate_names WHERE iso_language='ru'"),
        "orphan_alternate_name_rows": count("SELECT COUNT(*) FROM alternate_names a WHERE NOT EXISTS (SELECT 1 FROM geonames g WHERE g.geoname_id=a.geoname_id)"),
        "admin1_rows": count("SELECT COUNT(*) FROM admin1"),
        "admin2_rows": count("SELECT COUNT(*) FROM admin2"),
        "country_info_rows": count("SELECT COUNT(*) FROM country_info"),
        "feature_code_rows": count("SELECT COUNT(*) FROM feature_codes"),
        "blank_feature_class_source_rows": count("SELECT COUNT(*) FROM geonames WHERE feature_class=''"),
        "blank_feature_code_source_rows": count("SELECT COUNT(*) FROM geonames WHERE feature_code=''"),
        "blank_alternate_name_source_rows": count("SELECT COUNT(*) FROM alternate_names WHERE alternate_name=''"),
    }


def export_country_counts(connection: sqlite3.Connection, path: Path) -> int:
    query = """SELECT country_code, feature_code, COUNT(*) AS source_records
               FROM geonames WHERE feature_class='P'
               GROUP BY country_code, feature_code ORDER BY country_code, feature_code"""
    rows = 0
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("country_code", "feature_code", "populated_place_source_records"))
        for row in connection.execute(query):
            writer.writerow(row)
            rows += 1
    return rows


def verify_published_catalogue(raw: Path, output: Path, manifest_path: Path) -> dict:
    """Verify a completed import or a manifest awaiting its final rename."""
    result = json.loads(manifest_path.read_text(encoding="utf-8"))
    if result.get("source_manifest_sha256") != sha256_file(raw / "source_manifest.json"):
        raise ValueError("Catalogue source manifest differs from pinned source")
    database = output / "geonames.sqlite"
    db_entry = result.get("database", {})
    if not database.is_file() or database.stat().st_size != db_entry.get("bytes"):
        raise ValueError("Published catalogue database is missing or has wrong size")
    if sha256_file(database) != db_entry.get("sha256"):
        raise ValueError("Published catalogue database failed SHA-256 check")
    export_entry = result.get("country_feature_count_export", {})
    export = output / export_entry.get("file", "")
    if not export.is_file() or sha256_file(export) != export_entry.get("sha256"):
        raise ValueError("Published country/count CSV failed SHA-256 check")
    with closing(sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True)) as check:
        if check.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError("Published catalogue failed SQLite quick_check")
        if check.execute("SELECT COUNT(*) FROM geonames").fetchone()[0] != result["counts"]["geonames_source_rows"]:
            raise ValueError("Published catalogue row count differs from manifest")
    return result


def build(raw: Path, output: Path) -> dict:
    source_manifest = verify_raw(raw)
    output.mkdir(parents=True, exist_ok=True)
    database = output / "geonames.sqlite"
    temporary = output / "geonames.sqlite.part"
    manifest_path = output / "catalogue_manifest.json"
    pending_manifest = output / "catalogue_manifest.json.part"
    if manifest_path.exists():
        return verify_published_catalogue(raw, output, manifest_path)
    if database.exists() and pending_manifest.exists():
        recovered = verify_published_catalogue(raw, output, pending_manifest)
        os.replace(pending_manifest, manifest_path)
        return recovered
    if database.exists() or temporary.exists() or pending_manifest.exists():
        raise FileExistsError("Incomplete import needs inspection; source and database were left untouched")
    connection = sqlite3.connect(temporary)
    try:
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("PRAGMA synchronous=NORMAL")
        connection.execute("PRAGMA cache_size=-65536")
        create_schema(connection)
        geoname_rows = stream_zip_table(
            connection, raw / "allCountries.zip", "allCountries.txt",
            "geonames", GEONAMES_FIELDS, parse_geoname,
        )
        connection.commit()
        print(f"Imported full GeoNames source: {geoname_rows} rows", flush=True)
        alternate_rows = stream_zip_table(
            connection, raw / "alternateNamesV2.zip", "alternateNamesV2.txt",
            "alternate_names", ALTERNATE_FIELDS, parse_alternate,
        )
        connection.commit()
        print(f"Imported full alternate-name source: {alternate_rows} rows", flush=True)
        lookups = {
            "admin1": import_lookup(connection, raw / "admin1CodesASCII.txt", "admin1", 4),
            "admin2": import_lookup(connection, raw / "admin2Codes.txt", "admin2", 4),
            "country_info": import_lookup(connection, raw / "countryInfo.txt", "country_info", 19),
            "feature_codes": import_lookup(connection, raw / "featureCodes_en.txt", "feature_codes", 3),
        }
        connection.commit()
        finish_schema(connection)
        connection.commit()
        counts = compute_counts(connection)
        if counts["geonames_source_rows"] != geoname_rows or counts["alternate_name_source_rows"] != alternate_rows:
            raise RuntimeError("Imported source row counts do not reconcile")
        if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("SQLite quick_check failed")
        count_path = output / "populated_places_by_country_and_code.csv"
        country_code_rows = export_country_counts(connection, count_path)
        connection.close()
        result = {
            "source_provider": "GeoNames",
            "source_manifest_sha256": sha256_file(raw / "source_manifest.json"),
            "source_files": {name: source_manifest["files"][name] for name in REQUIRED},
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "database": {"file": database.name, "bytes": temporary.stat().st_size, "sha256": sha256_file(temporary)},
            "country_feature_count_export": {"file": count_path.name, "rows": country_code_rows, "sha256": sha256_file(count_path)},
            "counts": counts,
            "lookup_import_rows": lookups,
            "definition": "All GeoNames feature points and alternate-name records in the pinned full dump; P class is not a census of legal cities.",
            "known_limits": [
                "Point locations do not provide building footprints, shorelines or terrain meshes.",
                "Administrative codes and alternate names may be missing or historical.",
                "GeoNames P class includes neighborhoods, abandoned and historical settlements.",
                "No Minecraft region is marked built or validated by this import.",
            ],
        }
        with pending_manifest.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, database)
        os.replace(pending_manifest, manifest_path)
        return result
    finally:
        try:
            connection.close()
        except Exception:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    result = build(args.raw.resolve(), args.out.resolve())
    print(json.dumps(result["counts"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
