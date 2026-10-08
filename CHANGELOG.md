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
* Send an identifying User-Agent, URL-encode city names, add request timeouts and
  report Overpass/Nominatim failures in `Trip.errors`.
* Concurrent `findTotalTrip` calls no longer share the routing graph.
* Add `TripService(httpClient:)`, `TripService.useOnlineData()`, `Graph.fromFile`,
  `buildGraphFromOsmElements`; remove the leftover template `Calculator` class.
