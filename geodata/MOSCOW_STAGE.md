# Isolated Moscow Earth pilot

This is evidence from `D:\1-Game\support\staging-earth-sector-20261011`, **not**
the public survival world. The pilot server is stopped. `D:\1-Game\world-v2`,
`D:\2-Test`, and `D:\3-Backup` were not altered to make this register.

- Source: Tellus 0.8.3 with OpenStreetMap features around Cheremushki,
  Moscow. Source bbox: 55.6768–55.6800 N, 37.5550–37.5610 E.
- Minecraft extent: X 4,180,604–4,181,271; Z -7,494,975–-7,494,343.
  This is about 0.134 km² on the ground. The Tellus Mercator projection
  stretches east/west distance at this latitude: one game block spans about
  0.563 real-world metres locally. Horizontal scale is not globally 1:1.
- Saved full chunks in bbox: 1,720/1,720 (`coverage.json`). Of 35 OSM building
  footprints fully inside the bbox, 35 intersect saved complete chunks and
  have roof-like top material on at least half the footprint. This is a rough
  alignment test, not proof of correct interiors or exact replicas.
- Roads/paths: 80/149 OSM ways overlap road-like top materials over at least
  half their sampled pixels; 22/149 overlap less than a quarter. Road
  connectivity is unproven.
- One apartment at OSM way 217834048, Nakhimovsky Prospekt 63 building 2,
  was entered in-game around X 4,180,899, Y 92, Z -7,494,804. It has
  large mostly empty rooms. It has not been turned into a believable ruin.
- Potential unsupported `minecraft:banner` block entities were reported at
  X 4,181,159, Y 89, Z -7,494,657 and -7,494,655. Support and generator
  cause remain to be checked. Do not extrapolate from a few screenshots to
  a no-floating-fragments claim for the entire sector.
- The staged world does **not** demonstrate developed Moscow or any American
  city, furnished apartments, logical road network, airports, factories,
  railways, apocalypse damage, or a global Earth survival world.

Primary sources: [Tellus 0.8.3 release](https://github.com/Yucareux/Tellus/releases/tag/v0.8.3),
[OpenStreetMap data rights](https://www.openstreetmap.org/copyright),
[Natural Earth 5.1.1](https://github.com/nvkelso/natural-earth-vector/releases/tag/v5.1.1).
OSM data © OpenStreetMap contributors, available under ODbL.

The main `WORLD_COVERAGE.csv` deliberately marks all 195 reference countries
`not_generated` for *Earth terrain*. The existing main Minecraft world is
playable procedural terrain; it is not a generated Earth map. The 195 rows
prove only that generalized Natural Earth country polygons were joined to
the reference list. They do not prove playable land, regional structures,
safe spawn points, hydrology, or national boundaries in Minecraft.
