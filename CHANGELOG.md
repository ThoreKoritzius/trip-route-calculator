## 0.0.1

* Initial release.

## 0.0.2

* Link to repository, dependency updates 

## 0.0.3

* Stability improvements, package info updates

## 0.0.4

* Lower flutter version requirement

## 0.0.5

* Increase bounding box if no route is found

## 0.0.6

* Speed increases, bug fixes

## 0.0.7

* Fixing route length calculation 

## 0.0.8

* Fixing route length calculation

## 0.0.9

* Find entrances, better navigate places

## 0.0.10

* Find entrances, better navigate places

## 0.0.11

* Offline routing capability

## 0.0.13

* Improved reliability

## 0.0.14

* Fix offline routing: `useCity` never loaded the cached city file (uninitialised
  graph) and re-downloaded it every time; a failed download no longer caches an
  empty graph or switches into offline mode.
* Fix loaded city graphs containing every edge twice.
* Fix `preferWalkingPaths`: footways are now detected via `highway=footway|pedestrian|path|steps|living_street`
  (previously almost never matched) and the preference is applied per edge, also offline.
* Exclude motorways and `foot=no` ways from pedestrian routing.
* Fix `duplicationPenalty` only applying when an edge was reused in the opposite direction.
* Fix "path not found" errors when consecutive waypoints snap to the same node,
  segments shorter than 10 cm breaking ways apart, and route points being
  duplicated at leg boundaries.
* Never remove the largest connected component; add a minimum bounding box padding
  so nearby/collinear waypoints still get routable data.
* Fix entrance detection for entrances on the building outline.
* `forceIncludeWaypoints` now also includes the first waypoint.
* **Fix online routing in 0.0.13**: overpass-api.de now rejects requests without
  an identifying User-Agent (HTTP 406), which 0.0.13 did not send. Also URL-encode city names, add request timeouts and
  report Overpass/Nominatim failures in `Trip.errors`.
* Non-JSON responses (e.g. HTML error pages) and Overpass runtime errors reported
  with HTTP 200 (query timeouts with truncated data) are now handled as failures
  instead of throwing a `FormatException` or routing on partial data.
* `findTotalTrip` routes on a local graph, so a future `await` between fetching
  and routing cannot mix up concurrent calls.
* Add `TripService(httpClient:)`, `TripService.useOnlineData()`, `Graph.fromFile`,
  `buildGraphFromOsmElements`; remove the leftover template `Calculator` class.
* Snap waypoints to the closest point on the walkable network instead of the
  nearest node, so routes start/end on the way next to each waypoint. Waypoints
  further than `maxSnapDistance` (default 1000 m) are reported in `Trip.errors`.
* `forceIncludeWaypoints` and building entrances now count the off-network
  connectors in `Trip.distance`.
* New `findTotalTrip` options: `footwayCostFactor` (default 0.9, was a fixed 0.95)
  and `avoidSteps`. Ways with `access=private|no` are excluded unless `foot=yes`.
* `replaceWaypointsWithBuildingEntrances` also works after `useCity` (needs
  connectivity, falls back to the original waypoints).
* `useCity(maxAge:)` refreshes outdated caches (falls back to the stale cache when
  the download fails). Cache files now record their download time; caches are
  written atomically.
* Web support: file access is only used where available; on the web
  `useCity` keeps the data in memory.
* Retry Overpass/Nominatim requests on transient failures (HTTP 429/5xx, timeouts,
  Overpass runtime errors) with exponential backoff and `Retry-After` support;
  optional `fallbackOverpassUrls`. Entrance lookups fail fast without retries.
* Allow `latlong2` 0.10.
* Performance (Aachen, 209k nodes): offline cities load 5x faster with 4x less
  memory from a compact binary cache (`<city>.trg`, 4x smaller; JSON caches are
  migrated automatically); routing uses A* and a spatial index for snapping
  (10 waypoints: 172 ms → 0.5 ms, 21 km route: 229 ms → 85 ms).
* Online requests fetch roads and entrances in parallel, reuse the fetched area
  for later requests inside it (`onlineCacheDuration`, default 10 minutes) and
  cache successful entrance lookups.
* Add `Graph.toBytes`/`Graph.fromBytes`, `Graph.revision`/`markModified` and
  `saveGraph(asJson:)`. Default `getCityPath` is now `<city>.trg`.
* Add `benchmark/benchmark.dart`.
* `TripService.lastCityError` explains why `useCity` could not download a city
  (e.g. city not found, Overpass busy).

## 0.0.15

* **Privacy:** new `RoutingPrivacy.area` mode (`TripService(privacy:)` or per
  `findTotalTrip` call). Map data is requested for whole cells of a fixed ~1 km
  grid (`privacyCellDegrees`), so the map server learns only which cells the
  waypoints lie in instead of their exact positions; no entrance lookups.
  Downloads about 3x as much map data. Adds `findGridBounds`.
* Offline routing (after `useCity`) no longer looks up building entrances
  online: `replaceWaypointsWithBuildingEntrances` is skipped there, so offline
  routing never sends waypoint coordinates.
