"""Download a pinned GeoNames source snapshot, streaming to disk.

This acquires reference data only. It does not import Minecraft worlds or claim
that any location has been built in game. GeoNames data is CC BY 4.0 and supplied
as-is: https://download.geonames.org/export/dump/readme.txt
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


BASE_URL = "https://download.geonames.org/export/dump/"
FILES = (
    "allCountries.zip",
    "alternateNamesV2.zip",
    "admin1CodesASCII.txt",
    "admin2Codes.txt",
    "countryInfo.txt",
    "featureCodes_en.txt",
)
MAX_FILE_BYTES = 2_000_000_000
CHUNK_BYTES = 1024 * 1024


def digest_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def write_manifest(path: Path, manifest: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".part")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def download_one(directory: Path, name: str, manifest: dict) -> dict:
    if name not in FILES:
        raise ValueError(f"Unapproved GeoNames file: {name}")
    destination = directory / name
    prior = manifest["files"].get(name)
    if prior:
        if not destination.is_file():
            raise RuntimeError(f"Manifest entry has no file: {name}")
        actual_size, actual_hash = digest_file(destination)
        if (actual_size, actual_hash) != (prior["bytes"], prior["sha256"]):
            raise RuntimeError(f"Pinned data changed on disk: {name}")
        print(f"Verified cached {name}: {actual_size} bytes")
        return prior
    if destination.exists():
        raise RuntimeError(f"Unmanifested file exists, refusing overwrite: {name}")

    part = directory / (name + ".part")
    if part.exists():
        # Only this exact known partial file is replaced. A partial is never a
        # trusted cache, because its source snapshot may have changed.
        part.unlink()
    request = urllib.request.Request(
        BASE_URL + name,
        headers={"User-Agent": "POSLE-geodata/1.0 (reference catalogue; no API scraping)"},
    )
    digest = hashlib.sha256()
    size = 0
    try:
        with urllib.request.urlopen(request, timeout=90) as response, part.open("xb") as handle:
            if response.status != 200:
                raise RuntimeError(f"HTTP {response.status} for {name}")
            expected_header = response.headers.get("Content-Length")
            expected = int(expected_header) if expected_header else None
            if expected is not None and expected > MAX_FILE_BYTES:
                raise RuntimeError(f"Source file exceeds size limit: {name}")
            while True:
                chunk = response.read(CHUNK_BYTES)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_FILE_BYTES:
                    raise RuntimeError(f"Downloaded file exceeds size limit: {name}")
                handle.write(chunk)
                digest.update(chunk)
            handle.flush()
            os.fsync(handle.fileno())
            if expected is not None and size != expected:
                raise RuntimeError(f"Incomplete download: {name}: {size} != {expected}")
            entry = {
                "url": BASE_URL + name,
                "bytes": size,
                "sha256": digest.hexdigest(),
                "retrieved_at_utc": datetime.now(timezone.utc).isoformat(),
                "http_last_modified": response.headers.get("Last-Modified"),
                "http_etag": response.headers.get("ETag"),
                "license": "CC BY 4.0 (GeoNames dump README)",
            }
        os.replace(part, destination)
        print(f"Downloaded {name}: {size} bytes; SHA-256 {entry['sha256']}")
        return entry
    except BaseException:
        # Keep a partial only as explicit incomplete evidence; it is never used
        # as a valid archive and is replaced on the next run.
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="New immutable raw snapshot directory")
    parser.add_argument("--only", choices=FILES, nargs="*", default=list(FILES))
    args = parser.parse_args()
    directory = args.out.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    manifest_path = directory / "source_manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("provider") != "GeoNames" or manifest.get("base_url") != BASE_URL:
            raise RuntimeError("Existing manifest belongs to a different source")
    else:
        manifest = {
            "provider": "GeoNames",
            "base_url": BASE_URL,
            "source_readme": BASE_URL + "readme.txt",
            "license": "CC BY 4.0",
            "files": {},
            "scope_note": "Raw source files only; no Minecraft generation or city census claim",
        }
    for name in args.only:
        entry = download_one(directory, name, manifest)
        manifest["files"][name] = entry
        write_manifest(manifest_path, manifest)
    print(f"Snapshot manifest: {manifest_path}")


if __name__ == "__main__":
    main()
