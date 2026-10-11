"""Extract the master's R001–R082 index without claiming implementation.

The owner-provided master remains outside the public repository. This script
accepts its path as an argument and writes only the redacted requirement index.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import re
from pathlib import Path


FIRST_ID = 1
LAST_ID = 82
START_MARKER = "34. REQUIREMENT COVERAGE LEDGER"
END_MARKER = "35. FINAL INSTRUCTION"
ROW_RE = re.compile(r"^R(?P<id>\d{3})\s+(?P<body>.+)$")

# Evidence only. An imported map point or a loaded shader does not satisfy the
# gameplay/visual acceptance criteria of the corresponding full requirement.
PROGRESS = {
    2: ("IN PROGRESS", "Work continues in the main project without changing the separate test server"),
    4: ("IN PROGRESS", "Independent server, geography, client/site and security reviews performed"),
    5: ("IN PROGRESS", "Existing public repository cloned; source manifests and project rules prepared locally"),
    7: ("IN PROGRESS", "Main world, server mods, TLauncher instance and public site inventoried"),
    8: ("RESEARCHING", "Forge 1.20.1 baseline verified; final whole-pack compatibility undecided"),
    9: ("IN PROGRESS", "Original GeoNames, Natural Earth and Tellus sources inspected before custom geography work"),
    10: ("IN PROGRESS", "195 reference entries joined to Natural Earth polygons; 0 live Earth sectors verified"),
    11: ("IN PROGRESS", "Russia, US, France and Armenia represented in source catalogues; no playable Earth regions verified"),
    28: ("IN PROGRESS", "Existing TLauncher instance has enabled DMS/Oculus and resource packs; new visual acceptance untested"),
    80: ("RESEARCHING", "Backup exists; independent restore test pending"),
}


def owner_for(number: int) -> str:
    if 10 <= number <= 17 or number == 42:
        return "geography"
    if 18 <= number <= 26:
        return "architecture"
    if 27 <= number <= 33:
        return "horror_art"
    if 34 <= number <= 41:
        return "gameplay"
    if 43 <= number <= 52:
        return "accounts_security"
    if 53 <= number <= 58:
        return "player_appearance"
    if number == 59:
        return "audio_voice"
    if 60 <= number <= 63:
        return "social"
    if 64 <= number <= 73:
        return "distribution"
    if 74 <= number <= 76:
        return "performance"
    if number in (78, 79, 81, 82):
        return "quality_assurance"
    if number == 80:
        return "operations"
    return "lead"


def extract(text: str, sha256: str) -> list[dict[str, str]]:
    start = text.find(START_MARKER)
    end = text.find(END_MARKER, start)
    if start < 0 or end < 0:
        raise ValueError("The complete requirement ledger was not found")
    section = text[start:end]
    groups: list[tuple[int, list[str]]] = []
    for line in section.splitlines():
        match = ROW_RE.match(line.strip())
        if match:
            groups.append((int(match["id"]), [match["body"].strip()]))
        elif groups and line.startswith("     ") and line.strip():
            groups[-1][1].append(line.strip())

    numbers = [number for number, _ in groups]
    if numbers != list(range(FIRST_ID, LAST_ID + 1)):
        raise ValueError(f"Expected consecutive R001–R082; got {numbers}")

    rows: list[dict[str, str]] = []
    for number, parts in groups:
        body = " ".join(parts)
        description, separator, sections = body.rpartition(": ")
        if not separator or not sections.endswith("."):
            raise ValueError(f"Missing section references for R{number:03d}")
        status = "NOT STARTED"
        evidence = ""
        blocker = ""
        if number == 1:
            status = "BLOCKED"
            evidence = "Previous migration checkpoint verified; redundant archive retained"
            blocker = "Automatic review rejected permanent recursive deletion"
        elif number in PROGRESS:
            status, evidence = PROGRESS[number]
        rows.append(
            {
                "id": f"R{number:03d}",
                "description": description,
                "section_refs": sections[:-1],
                "owner": owner_for(number),
                "status": status,
                "evidence": evidence,
                "blocker": blocker,
                "source_sha256": sha256,
            }
        )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("master", type=Path, help="Private owner-provided master TXT")
    parser.add_argument("output", type=Path, help="Public-safe requirements CSV")
    args = parser.parse_args()
    raw = args.master.read_bytes()
    rows = extract(raw.decode("utf-8-sig"), hashlib.sha256(raw).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} requirements to {args.output}")


if __name__ == "__main__":
    main()
