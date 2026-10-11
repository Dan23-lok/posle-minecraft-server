"""Pin original Natural Earth v5.1.1 GeoJSON sources outside the game world.

This downloads reference geometry only. It neither generates Minecraft terrain
nor marks any of the 195 baseline countries as complete.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen


BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.1/geojson/"
FILES = (
    "ne_10m_admin_0_countries.geojson",
    "ne_10m_land.geojson",
)
CHUNK = 1024 * 1024


def download(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / "source_manifest.json"
    if manifest_path.exists():
        raise FileExistsError(f"Already pinned: {manifest_path}")
    files: dict[str, dict] = {}
    for name in FILES:
        path = output / name
        temporary = output / (name + ".part")
        if path.exists() or temporary.exists():
            raise FileExistsError(f"Existing source or incomplete download: {name}")
        request = Request(BASE + name, headers={"User-Agent": "POSLE-geodata/1.0"})
        digest = hashlib.sha256()
        size = 0
        with urlopen(request, timeout=60) as response, temporary.open("wb") as handle:
            if response.status != 200:
                raise RuntimeError(f"Unexpected HTTP status {response.status} for {name}")
            while chunk := response.read(CHUNK):
                handle.write(chunk)
                digest.update(chunk)
                size += len(chunk)
        with temporary.open("r", encoding="utf-8") as handle:
            header = handle.read(100)
        if '"type"' not in header and "{" not in header:
            raise ValueError(f"Download is not GeoJSON: {name}")
        os.replace(temporary, path)
        files[name] = {"url": BASE + name, "bytes": size, "sha256": digest.hexdigest()}
    result = {
        "provider": "Natural Earth",
        "version": "5.1.1",
        "retrieved_at_utc": datetime.now(timezone.utc).isoformat(),
        "license": "public domain",
        "terms_url": "https://www.naturalearthdata.com/about/terms-of-use/",
        "release_url": "https://github.com/nvkelso/natural-earth-vector/releases/tag/v5.1.1",
        "files": files,
        "scope": "Generalized Earth land/country polygons; no structures, terrain heights, or game coverage.",
    }
    manifest_path.write_text(json.dumps(result, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(download(args.out.resolve()), indent=2, ensure_ascii=False))
