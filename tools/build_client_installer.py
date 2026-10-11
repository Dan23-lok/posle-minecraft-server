"""Build the redistribution-safe client ZIP from an explicit source allowlist.

The archive contains only installer text and a download manifest. It does not
redistribute Minecraft, Java, Forge, mods, resource packs, or shaders.
"""

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client-pack"
FILES = (
    "Install-Client.cmd",
    "Install-HorrorClient.ps1",
    "Build-BornInChaosAnimationFix.ps1",
    "Forge-ClientReadiness.ps1",
    "Uninstall-Client.cmd",
    "Uninstall-HorrorClient.ps1",
    "client-modpack.json",
    "historical/client-modpack-2026.10.11.4.json",
    "README-RU.md",
)


def build(output: Path) -> dict:
    manifest = json.loads((CLIENT / "client-modpack.json").read_text(encoding="utf-8-sig"))
    if manifest.get("minecraft_version") != "1.20.1" or not manifest.get("pack_version"):
        raise ValueError("client manifest version is missing or unexpected")
    source = {name: (CLIENT / name).read_bytes() for name in FILES}
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix=".posle-installer-", suffix=".zip", dir=output.parent)
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w") as archive:
            for name, data in source.items():
                info = zipfile.ZipInfo(name, date_time=(2026, 10, 11, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, data, compresslevel=9)
        with zipfile.ZipFile(temporary) as archive:
            if archive.namelist() != list(FILES):
                raise ValueError("archive membership differs from allowlist")
            for name, data in source.items():
                if archive.read(name) != data:
                    raise ValueError(f"archive entry mismatch: {name}")
            if archive.testzip() is not None:
                raise ValueError("archive CRC check failed")
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        os.replace(temporary, output)
        return {"pack_version": manifest["pack_version"], "sha256": digest,
                "bytes": output.stat().st_size, "entries": list(FILES)}
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.output), ensure_ascii=False, indent=2))
