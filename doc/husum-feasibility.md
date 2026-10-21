# Husum prebuilt walking-graph feasibility — 2026-10-21

**Result: feasible for a Husum pilot.** A real regional OSM extract produced a
1.12 MB graph (539 KB gzipped). The existing routing engine loaded and routed it
without an API key or HTTP requests. This is a reproducible Linux feasibility
study, not a deployed app feature or a worldwide capacity/route-quality claim.

## Source, coverage and environment

- [Geofabrik Schleswig-Holstein](https://download.geofabrik.de/europe/germany/schleswig-holstein.html),
  `schleswig-holstein-latest.osm.pbf`: 159,108,553 bytes; OSM data timestamp
  **2026-10-20T20:23:47Z**. Exact source SHA-256 is recorded in
  [manifest.json](husum-study/manifest.json). The `latest` URL is mutable.
- Experimental rectangular coverage: longitude **8.98–9.14**, latitude
  **54.43–54.53**, roughly 10 × 11 km around Husum. This is not an administrative
  boundary. Complete crossing ways are retained, so some nodes extend outside
  the rectangle; these do not establish coverage outside it.
- Host: 4 virtual CPUs (AMD EPYC-Milan, exposed at 2 GHz), 7.7 GiB RAM,
  Linux x86_64. This is the development host; production VPS capacity was not
  inspected. No swap was used by the measured commands.
- Engine: package source `7466a19`, version 0.0.15 (unpublished at study time),
  `TRG1` binary format; Dart 3.13.5 AOT executable. Python extraction uses
  pyosmium 4.3.2. No production library code or package version changed.

The binary graph records its build timestamp, so a rebuild produces a new
artifact hash even with identical source data. Record a new manifest when
publishing a new build.

The source download succeeded in 53.32 seconds on the measured attempt; other
attempts encountered 503s/timeouts. This is not a reliable download-time promise.
The important difference from live Overpass is that an interrupted scheduled
refresh need not prevent routing with the last valid published graph.

## Measurements

Sizes below are decimal MB/KB. RSS is the entire standalone process, not just the
graph. Timings are observed on this host, with filesystem caches already warm.

| Stage / artifact | Observed result |
| --- | --- |
| Regional source download | 159.11 MB |
| Filter/extract complete Husum candidate ways | 23.19 s including intermediate JSON; peak RSS 348.02 MB |
| Intermediate JSON | 2.32 MB |
| Candidate network before small-island pruning | 21,202 nodes / 4,517 ways; zero missing way-node locations |
| Graph after package pruning | 21,063 nodes / 45,996 directed edges; one connected component |
| JSON decode + build + write | 109.09 ms total; build portion 34.90 ms; peak RSS about 51 MB |
| Binary graph | **1,124,555 bytes** |
| Gzip graph | **539,237 bytes** |
| Load, five fresh process runs | **15.08–23.62 ms** |
| RSS before / immediately after graph load | about 7.6 / 17.0–17.6 MB |
| Peak RSS including 202 route probes, five runs | **79.8–80.3 MB** |
| Sampled routing, per-run median | **2.66–2.98 ms** |
| Sampled routing, per-run 95th percentile | **12.21–13.68 ms** |

An initial Python callback for every regional node took 258.06 seconds and about
340 MB RSS. Filtering objects in C++ before Python reduced the extraction to
23.19 seconds with **byte-identical intermediate JSON**. Both JSON files had
SHA-256 `b3c9e9d60bb255d83b125d7c5d4f26bc3bff53f4358f0a241eae761654f7b390`.
This is one extraction comparison; input filesystem cache and concurrent host
work also affect timings. The optimized run overlaps the final part of the
baseline run. Raw measurements are in [husum-study](husum-study/).

## Routing and delivery evidence

The harness loads the saved graph through `TripService.useCity` and injects an
HTTP client that rejects/counts every request. It also enables entrance
replacement in 0.0.15 to verify the package skips network enrichment offline.

- Public-coordinate market/harbour/castle/market loop: **1,524 m**, 84 path
  points, no errors; initial computation about 7 ms. The start/end snap is about
  26 m from the illustrative market coordinate, so this does not establish
  entrance-level navigation.
- Public-coordinate station/market route: **769 m**, 57 path points, no errors.
- **200 deterministic random node-pair routes:** zero failures and zero HTTP
  requests. Nodes are sampled from the largest component; this measures routing
  through its topology, not arbitrary POI accessibility. Median route distance
  is about 5.17 km. Five repeated process runs also passed.
- A clearly outside waypoint produces an explicit off-network error. A
  half-truncated binary graph is rejected.
- Local Python static server: **20/20 transfers** with concurrency four passed
  content-length and SHA-256 checks; server process peak RSS about 35.8 MB.
  Median transfer about 15 ms over **loopback**, not a WAN/CDN/mobile load test.

This demonstrates graph generation, file delivery and actual offline path
calculation. It does not validate all OSM access rules or certify every walking
route as safe/legal. The filters mirror the current package and exclude
motorways, construction and prohibited pedestrian access; conditional access,
barriers and other routing-policy details still need review.

The same graph was also loaded and routed with the **published 0.0.14** package:
both tours plus 200 sampled pairs passed, with zero HTTP calls. That compatibility
probe disables entrance enrichment explicitly; 0.0.14 otherwise attempts optional
entrance requests even in offline mode. Binary-format compatibility does not mean
the current app already downloads or activates these graphs. Recorded results:
[compat-0.0.14.json](husum-study/compat-0.0.14.json).

## What this means for hosting and the app

For **Husum**, serving a 1.12 MB static file is a small storage/CPU burden. Two
versions occupy about 2.25 MB; 1,000 uncompressed downloads transfer about
1.12 GB (about 539 MB for the measured gzipped artifact). A regional extraction
worker peaked below 350 MB in this study. There is no need for an Overpass
server or an API key for this path.

Do not extrapolate a worldwide footprint from one small, relatively flat city.
Larger/dense regions, boundary overlap, temporary source files, refresh cadence
and parallel build workers change storage and memory requirements. The full
regional PBF scan is shared overhead: we should build multiple areas from one
regional pass, rather than scan this 159 MB source independently for each tile.

The app would keep bounded graph files on disk and only active routing areas in
memory. The measured 80 MB is a standalone Linux probe; Flutter, maps and audio
add their own memory use. Android load, decoding, spatial-index construction,
frame latency and background/resume behavior are **not tested** here.

Before an app pilot:

1. Add a manifest-based downloader with a byte limit, SHA-256 verification,
   temporary files/atomic activation, versioning, fallback to a last good graph
   and a bounded disk cache. `Graph.fromBytes` alone is not an integrity check.
2. Select areas by route coverage, use boundary margins and handle routes that
   cross areas; report unsupported coverage instead of silently claiming a
   partial graph is complete. Seamless tile stitching is not implemented.
3. Serve versioned artifacts plus the manifest on the existing backend/static
   server; keep OSM attribution and licensing information with downloads.
   Generated data is [OpenStreetMap / ODbL](https://www.openstreetmap.org/copyright).
4. Wire the app's planner to the downloaded graph; keep route cancellation and
   state fencing. Log timings/cache/error categories without user coordinates.
5. Test first download, airplane-mode routing after restart, interrupted and
   corrupted downloads, failed refresh retaining the old graph, cache eviction,
   and out-of-area routes on Android.

**No graph files have been deployed, no production database changed, no main
branch updated, and no package release published by this study.** Locally built
artifacts are under `build/husum-study/` and are intentionally not checked in.

## Reproduce

Run from the package repository with Python 3, a C++-compatible pyosmium wheel,
Flutter/Dart and GNU `time`. Allow a few hundred MB of temporary disk space.
The source download is free/keyless; do not replace it with bulk live Overpass
queries. Record the source hash/timestamp for every new run.

```sh
python3 -m venv /tmp/husum-study-venv
/tmp/husum-study-venv/bin/pip install -r tool/husum_study/requirements.txt
mkdir -p build/husum-study
curl --fail --location --connect-timeout 10 --max-time 180 \
  --user-agent 'Worldbummlr-Husum-Study/1.0 (+https://github.com/ThoreKoritzius/trip-route-calculator)' \
  --output build/husum-study/source.osm.pbf \
  https://download.geofabrik.de/europe/germany/schleswig-holstein-latest.osm.pbf
sha256sum build/husum-study/source.osm.pbf
/tmp/husum-study-venv/bin/python -m unittest discover -s tool/husum_study -p 'test_*.py'
/usr/bin/time -v /tmp/husum-study-venv/bin/python tool/husum_study/extract.py \
  build/husum-study/source.osm.pbf build/husum-study/elements.json
flutter pub get
dart compile exe tool/husum_study/probe.dart -o build/husum-study/probe
/usr/bin/time -v build/husum-study/probe build \
  build/husum-study/elements.json build/husum-study/husum.trg
/usr/bin/time -v build/husum-study/probe route \
  build/husum-study/husum.trg build/husum-study/routes.json
/tmp/husum-study-venv/bin/python tool/husum_study/serve_probe.py build/husum-study/husum.trg
flutter test --exclude-tags network
flutter analyze --fatal-infos
```

`probe route` exits nonzero on a failed route, unexpected HTTP request, failure to
reject out-of-area input or a truncated graph. Its stdout/file output is JSON
for comparison with the recorded measurements. Full graphs and regional source
files must remain outside Git/package releases unless deliberately distributed
as separately versioned data artifacts.
