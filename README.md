# Trip Route Calculator

**trip_routing** is a Flutter package for on-device walking routes with multiple waypoints. It downloads the walkable OpenStreetMap network around your waypoints (or a whole city, for offline use) and calculates the route on the device, without a routing server. The result is a polyline of `LatLng` points that drops straight into Flutter map widgets.

It powers the AI travel app [Worldbummlr](https://worldbummlr.com?ref=trip_routing).

---

## Key Features

- **Routing on the device**: no routing server, no API key, no per-request cost. Map data comes from OpenStreetMap through the public Overpass API, or from an offline city cache.
- **Offline cities**: download a city once (Aachen: 16 s, 11 MB) and route without a connection afterwards.
- **Fast**: a route across a city takes milliseconds on the device; see [Performance](#performance).
- **Made for pedestrians**: prefers footpaths, can avoid stairs, excludes motorways and private ways, and can route to building entrances.
- **Multiple waypoints**: plan tours with many stops, optionally discouraging walking the same street twice.
- **All platforms**: Android, iOS, macOS, Windows, Linux and web (on the web, offline cities are kept in memory).

---

## Installation

Add the package to your Flutter app by including the following in your `pubspec.yaml` file:

```yaml
dependencies:
  trip_routing: ^0.0.14
```

Then, run:

```bash
flutter pub get
```

---

## Usage

Here is a basic example of using the package to calculate a route:

```dart
import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';

final waypoints = [
    const LatLng(50.77437074991441, 6.075419266272186),
    const LatLng(50.774717242584515, 6.083980842518867),
];

final routing = TripService();
final trip = await routing.findTotalTrip(
    waypoints,
    preferWalkingPaths: true,
    replaceWaypointsWithBuildingEntrances: true,
);
print('Calculated route: ${trip.route}');
print('Distance: ${trip.distance} meters');
print('Errors: ${trip.errors}');
```

Network and routing problems are reported in `trip.errors` instead of being thrown.

### `findTotalTrip` Parameters

- **`waypoints`** *(List\<LatLng\>)*: Locations (latitude and longitude) between which the route is calculated, in visiting order.
- **`preferWalkingPaths`** *(bool)*: Whether to prioritize walking paths over other types of paths. Default: `true`.
- **`replaceWaypointsWithBuildingEntrances`** *(bool)*: Whether to replace waypoints inside buildings with the building's entrance, if one is mapped. Default: `false`.
- **`forceIncludeWaypoints`** *(bool)*: Whether to force the inclusion of waypoints in the final route, even if they are not on a road. The off-road distance is counted. Default: `false`.
- **`duplicationPenalty`** *(double)*: Penalty (in meters) added whenever an edge already used by a previous leg is reused, to discourage out-and-back routes. Default: `0.0`.
- **`footwayCostFactor`** *(double)*: Cost multiplier for dedicated walking ways when `preferWalkingPaths` is set; lower values prefer them more strongly. Default: `0.9`.
- **`avoidSteps`** *(bool)*: Make stairs 5x as expensive, e.g. for wheelchair or stroller routes. Default: `false`.
- **`maxSnapDistance`** *(double)*: Waypoints are snapped to the closest point on a walkable way; waypoints further away than this (in meters) are reported in `errors`. Default: `1000`.

### Result

`findTotalTrip` returns a `Trip`:

- **`route`** *(List\<LatLng\>)*: The points forming the route, from the first to the last waypoint.
- **`distance`** *(double)*: The total distance of the route in meters.
- **`errors`** *(List\<String\>)*: Problems encountered, e.g. an unreachable waypoint or an unavailable map server. Empty on success.
- **`boundingBox`** *(List\<double\>?)*: The area whose map data was used in online mode, as `[minLat, minLon, maxLat, maxLon]`.

---

## Offline Routing

You can save routing data on disk for a specific city to enable offline routing. To initialize offline routing, call the `useCity` function:

```dart
final routing = TripService();
await routing.useCity('Aachen');
```

This will fetch and store routing information for the specified city on first use, ensuring fast subsequent routing even without internet access. `useCity` returns `false` if the city data could not be fetched; `routing.lastCityError` then says why (e.g. city not found, or the public Overpass server is busy).

By default the data is stored as `<city>.trg` in the current working directory, in a compact binary format (about 4x smaller and 5x faster to load than the JSON caches of version 0.0.13 and earlier, which are migrated automatically). On mobile platforms, override `getCityPath` to store it in a writable location (e.g. from `path_provider`):

```dart
class AppTripService extends TripService {
  @override
  Future<String> getCityPath(String cityName) async =>
      '${(await getApplicationSupportDirectory()).path}/$cityName.trg';
}
```

Pass `maxAge` to refresh outdated data (the stale cache is still used if the refresh fails):

```dart
await routing.useCity('Aachen', maxAge: const Duration(days: 30));
```

On the web there is no file system, so the city data is kept in memory only.

Call `routing.useOnlineData()` to switch back to fetching live data around the waypoints.

---

## Performance

All numbers were measured on the city of Aachen (209,000 nodes) on a MacBook; phones are typically several times slower. Reproduce them with `dart run benchmark/benchmark.dart`.

| | 0.0.14 | 0.0.13 |
|---|---|---|
| Load an offline city | 88 ms | 423 ms |
| Offline city file | 11 MB | 43 MB |
| Memory after loading | +110 MB | +456 MB |
| Route, 900 m | 0.7 ms | 37 ms |
| Route, 21 km across the city | 85 ms | 229 ms |
| Route with 10 waypoints | 0.5 ms | 172 ms |
| Repeating an online request in the same area | ~1 ms | full download (5–30 s) |

How it gets there:

- **A\* search** towards the destination instead of exploring the whole city. Routes are still optimal: on 300 random trips through Aachen, distances matched the previous exhaustive search exactly.
- **A spatial index** finds the nearest walkable way for each waypoint in about 0.05 ms instead of scanning every street.
- **A compact binary city format** that loads without parsing JSON.
- **Fewer network round trips online**: roads and building entrances are fetched in parallel, the fetched area is reused for 10 minutes for later requests inside it (`TripService(onlineCacheDuration: ...)`), and entrance lookups are cached.

---

## Compared with routing servers

Most apps get walking routes from a routing server such as Google Maps, [OSRM](https://project-osrm.org) or [Valhalla](https://valhalla.github.io/valhalla/). trip_routing computes them on the device instead:

| | trip_routing | OSRM / Valhalla (self-hosted or public) | Google Maps Routes API |
|---|---|---|---|
| Where routing runs | In your app | On a server | Google's servers |
| Works offline | Yes, after `useCity` | No | No |
| Setup | Add the package | Run a server, preprocess map data for hours | API key with billing |
| Cost per route | None | Server costs | Billed per request |
| Map data | OpenStreetMap | OpenStreetMap | Google |

We routed seven walking trips through Aachen with trip_routing and with the public OSRM (foot profile) and Valhalla (pedestrian) servers on 8 October 2026, using the same stop coordinates and current OpenStreetMap data:

| Trip | trip_routing | OSRM | Valhalla |
|---|---:|---:|---:|
| README example | 954 m | 960 m | 960 m |
| Cathedral → Main station | 1,179 m | 1,210 m | 1,231 m |
| Ponttor → Lousberg (park, hill) | 900 m | 901 m | 1,098 m |
| Westpark → Elisenbrunnen | 1,610 m | 1,630 m | 1,567 m |
| Main station → University hospital | 4,317 m | 4,201 m | 4,312 m |
| Ponttor → Tivoli stadium | 2,239 m | 2,261 m | 2,350 m |
| Old town tour (5 stops) | 2,242 m | 2,369 m | 2,485 m |
| **Time per route (median)** | **0.7 ms** on the device | 79 ms round trip | 114 ms round trip |

- **Route quality**: trip_routing's distances differ from OSRM's by 2.0% on average and from Valhalla's by 5.8%; OSRM and Valhalla differ from each other by 5.6%. Where trip_routing is shorter, it walks ordinary public streets that the other engines rank lower.
- **Speed**: the server times are complete HTTP round trips from Germany, which an app would also pay; trip_routing's are pure computation on a laptop. Online, trip_routing first downloads map data for the area (typically a few seconds, then reused), and with an offline city it needs no network at all.
- **Google Maps** was not part of the comparison because its API requires a billing account.

### Known limitations

- Waypoints snap to the geometrically nearest walkable way. For a point deep inside a large building this can be a poor entry point (in the comparison, the University hospital trip is 116 m longer than OSRM's for this reason). Use `replaceWaypointsWithBuildingEntrances` for such points.
- Pedestrian squares mapped as areas (`area=yes`) are walked around rather than across.
- The public Overpass server is shared and sometimes overloaded. Requests are retried, but for production apps consider [your own Overpass instance or fallbacks](#networking) and offline cities.

---

## Networking

Requests to the public Overpass and Nominatim APIs send an identifying User-Agent and are retried on transient failures (busy server, timeouts). To use your own or additional Overpass instances:

```dart
final routing = TripService(
  osmClient: OsmClient(
    overpassUrl: 'https://my-overpass.example/api/interpreter',
    fallbackOverpassUrls: ['https://overpass.example.org/api/interpreter'],
  ),
);
```

---

## Where to Find More

- **Flutter Package**: [trip_routing on pub.dev](https://pub.dev/packages/trip_routing)
- **GitHub**: [https://github.com/ThoreKoritzius/trip-route-calculator](https://github.com/ThoreKoritzius/trip-route-calculator)

---

## Development

```bash
flutter test                                  # offline unit tests (HTTP is mocked)
flutter test --platform chrome test/web_test.dart  # browser tests
flutter test --tags network                   # live Overpass/Nominatim integration tests
dart run benchmark/benchmark.dart route Aachen.trg  # routing benchmark on a city cache
```

## Contributing

We welcome contributions! Feel free to open issues or submit pull requests to improve the package.

For major changes, please open an issue first to discuss what you would like to change.
