# Earth reference lists

These files are a **text-derived checklist**, not a generated Earth world. They
were extracted from the two owner-provided text files named in `manifest.json`.
The manifest records each input's byte count and SHA-256, and the checksums of
all generated outputs. `source_line` points back to the corresponding text row.

| File | Scope |
| --- | --- |
| `countries_195_reference.csv` / `.json` | 193 UN members plus 2 observer states, as stated in the supplied text |
| `areas_outside_195_baseline.csv` / `.json` | 54 separate ISO geographic codes in the supplied Russian report |
| `geonames_xk_note.json` | GeoNames XK code, deliberately separate from the ISO area list |

All entries have `listed_in_registry=true` and
`geometry_loaded=false`, `terrain_generated=false`, `spawn_validated=false`.
The country settlement and WUP urban-centre count fields in this text-derived
snapshot remain null/blank. A separate full GeoNames import is now recorded in
`geodata/sources/geonames_catalogue_2026-10-10.json` and
`docs/GEOGRAPHY_DATA.md`, but it has not been joined to these per-country
fields. UN WUP has not been imported. The reference locality is one
illustrative name, not a verified current capital. M49 broad regions are
statistical groupings; they do not describe every physical part of a country.
These files do not decide sovereignty or dispute boundaries.

To reproduce with Python 3, obtain the **exact** two source TXT files shown in
the manifest and run:

```text
python tools/extract_reference_catalog.py --en-source <English-master.txt> --ru-source <Russian-report.txt> --out geodata/reference
python -m unittest discover -s tests -p test_reference_catalog.py -v
```

The extractor rejects unexpected row counts, duplicate codes, invalid country
statuses/regions and overlapping categories. Compare the input SHA-256 values
with the manifest before treating a regenerated catalogue as the same snapshot.
The original text files are intentionally not copied into the repository.
