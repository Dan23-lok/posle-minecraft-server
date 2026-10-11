"""Build reviewable pack inventories from the two pinned manifests.

These CSVs record selected files and observed integration status. They do not
certify licensing, visual quality, or successful multiplayer gameplay.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT_PATH = ROOT / "client-pack" / "client-modpack.json"
SERVER_PATH = ROOT / "server" / "mods-lock.json"
DOCS = ROOT / "docs"


def read_json(path: Path) -> dict:
    # The client lockfile is emitted by PowerShell with a UTF-8 BOM.
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
    for row in rows:
        for field in fields:
            value = str(row.get(field, "")).lstrip()
            if value.startswith(("=", "+", "-", "@")):
                raise ValueError(f"Unsafe spreadsheet formula prefix in {field}")
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    client = read_json(CLIENT_PATH)
    server = read_json(SERVER_PATH)
    if client["minecraft_version"] != server["minecraft"]:
        raise ValueError("Minecraft versions differ")
    if client["forge_version"] != server["loader_version"]:
        raise ValueError("Forge versions differ")

    client_files = {row["filename"]: row for row in client["files"]}
    server_files = {row["filename"]: row for row in server["mods"]}
    if len(client_files) != len(client["files"]) or len(server_files) != len(server["mods"]):
        raise ValueError("Duplicate filenames in a lockfile")

    source_rows: list[dict] = []
    compatibility_rows: list[dict] = []
    for filename in sorted(client_files.keys() | server_files.keys(), key=str.casefold):
        c = client_files.get(filename)
        s = server_files.get(filename)
        if c and s and c["version"] != s["version"]:
            raise ValueError(f"Version differs for {filename}")
        if c and s and c.get("hash_algorithm", "").lower() == "sha512":
            if c["hash"].lower() != s.get("sha512", "").lower():
                raise ValueError(f"SHA-512 differs for {filename}")
        hash_relation = (
            "identical_sha512"
            if c and s and c.get("hash_algorithm", "").lower() == "sha512"
            else "different_algorithms_verify_installed_bytes"
            if c and s
            else "single_manifest"
        )

        name = (s or {}).get("name") or c["project"]
        version = (s or c)["version"]
        project_url = (c or {}).get("source_page") or (s or {}).get("official_url") or ""
        download_url = (c or {}).get("url") or (s or {}).get("download_url") or ""
        algorithm = (c or {}).get("hash_algorithm") or ("SHA512" if s.get("sha512") else "")
        digest = (c or {}).get("hash") or (s or {}).get("sha512") or ""
        if not digest:
            raise ValueError(f"No pinned digest for {filename}")
        origin = "local_source_in_repository" if (s or {}).get("source") == "local_custom_build" else "original_project"
        license_status = "MIT; AuthMod fork README" if filename.startswith("authmod-") else "not_individually_verified"

        source_rows.append(
            {
                "filename": filename,
                "name": name,
                "version": version,
                "type": (c or {}).get("folder") or "server_mod",
                "project_page": project_url,
                "download_url": download_url,
                "hash_algorithm": algorithm,
                "hash": digest,
                "origin": origin,
                "license_status": license_status,
                "redistribution": "source_only" if origin == "local_source_in_repository" else "not_bundled_download_from_original",
            }
        )
        compatibility_rows.append(
            {
                "filename": filename,
                "minecraft": client["minecraft_version"],
                "loader": server["loader"],
                "loader_version": server["loader_version"],
                "client": (s or {}).get("client_side") or ("included" if c else "unknown"),
                "server": (s or {}).get("server_side") or ("not_in_server_lock" if c else "unknown"),
                "in_client_manifest": str(bool(c)).lower(),
                "in_server_manifest": str(bool(s)).lower(),
                "manifest_hash_relation": hash_relation,
                "evidence": (
                    "server_boot; owner_file_hash; joint_gameplay_unverified"
                    if c and s
                    else "owner_file_hash; owner_TLauncher_launch_unverified"
                    if c
                    else "server_boot; feature_gameplay_unverified"
                ),
            }
        )

    write_csv(
        DOCS / "ASSET_SOURCES.csv",
        ["filename", "name", "version", "type", "project_page", "download_url", "hash_algorithm", "hash", "origin", "license_status", "redistribution"],
        source_rows,
    )
    write_csv(
        DOCS / "COMPATIBILITY.csv",
        ["filename", "minecraft", "loader", "loader_version", "client", "server", "in_client_manifest", "in_server_manifest", "manifest_hash_relation", "evidence"],
        compatibility_rows,
    )
    print(f"{len(source_rows)} distinct files; {len(client_files)} client; {len(server_files)} server")


if __name__ == "__main__":
    main()
