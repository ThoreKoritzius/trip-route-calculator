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
- **Privacy options**: a grid-based mode that hides exact waypoints from the map server, and offline routing that sends no coordinates at all.
- **All platforms**: Android, iOS, macOS, Windows, Linux and web (on the web, offline cities are kept in memory).

---

## Installation

Add the package to your Flutter app by including the following in your `pubspec.yaml` file:

```yaml
dependencies:
  trip_routing: ^0.0.15
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
- **`replaceWaypointsWithBuildingEntrances`** *(bool)*: Whether to replace waypoints with building entrances, if available. Sends the exact waypoints to Overpass, so it only applies online in the default privacy mode. Default: `false`.
- **`forceIncludeWaypoints`** *(bool)*: Whether to force the inclusion of waypoints in the final route, even if they are not on a road. The off-road distance is counted. Default: `false`.
- **`duplicationPenalty`** *(double)*: Penalty (in meters) added whenever an edge already used by a previous leg is reused, to discourage out-and-back routes. Default: `0.0`.
- **`footwayCostFactor`** *(double)*: Cost multiplier for dedicated walking ways when `preferWalkingPaths` is set; lower values prefer them more strongly. Default: `0.9`.
- **`avoidSteps`** *(bool)*: Make stairs 5x as expensive, e.g. for wheelchair or stroller routes. Default: `false`.
- **`privacy`** *(RoutingPrivacy?)*: What the map server may learn about the waypoints, see [Privacy](#privacy). Default: the service's `privacy` (`standard`).
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

By default the data is stored as `<city>.trg` in the current working directory, in a compact binary format. JSON caches written by version 0.0.13 and earlier are migrated automatically. On mobile platforms, override `getCityPath` to store it in a writable location (e.g. from `path_provider`):

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

Routing runs in the app, single-threaded. Measured on Aachen (154,000-node walking network) on a MacBook; phones are typically several times slower. Times are the median of 400 random trips (see [the comparison](#compared-with-routing-servers)):

| Trip length (straight line) | Median | 95th percentile |
|---|---:|---:|
| 0.3–1 km | 0.16 ms | 0.8 ms |
| 1–2 km | 0.66 ms | 1.7 ms |
| 2–5 km | 2.8 ms | 7.3 ms |

| Offline city (Aachen) | |
|---|---|
| Download and prepare on first use | about 16 s (Overpass) |
| File size | 11 MB |
| Load from disk | 88 ms |
| Memory | about 110 MB |

How it stays fast:

- **A\* search** towards the destination; it returns exactly the same routes as an exhaustive Dijkstra search (checked on 300 random trips).
- **A spatial index** finds the nearest walkable way for each waypoint in about 0.05 ms.
- **A compact binary city format** that loads without parsing JSON.
- **Fewer network round trips online**: roads and building entrances are fetched in parallel, the fetched area is reused for 10 minutes for later requests inside it (`TripService(onlineCacheDuration: ...)`), and entrance lookups are cached.

Reproduce with `dart run benchmark/benchmark.dart` and [`benchmark/engine_comparison`](benchmark/engine_comparison/README.md).

---

## Compared with routing servers

Most apps get walking routes from a routing server such as Google Maps, [OSRM](https://project-osrm.org) or [Valhalla](https://valhalla.github.io/valhalla/). trip_routing computes them on the device instead:

| | trip_routing | OSRM / Valhalla (self-hosted or public) | Google Maps Routes API |
|---|---|---|---|
| Where routing runs | In your app | On a server | Google's servers |
| Works offline | Yes, after `useCity` | No | No |
| Setup | Add the package | Run a server and preprocess the map data | API key with billing |
| Cost per route | None | Server costs | Billed per request |
| Who learns the waypoints | Nobody offline; see [Privacy](#privacy) | The server operator | Google |
| Map data | OpenStreetMap | OpenStreetMap | Google |

### Route quality and speed on 400 random trips

We routed 400 random walking trips through Aachen (October 2026) with trip_routing, a local OSRM server (v26.10, foot profile, contraction hierarchies) and the public Valhalla server (pedestrian costing). trip_routing and OSRM used the same OpenStreetMap snapshot. Trips start and end on the walking network and are evenly split into 0.3–1, 1–2 and 2–5 km straight-line distance.

**Route length** relative to the other engine (medians with 95% bootstrap confidence intervals):

| | Median ratio | Middle 50% of trips | Within ±5% | Within ±10% |
|---|---:|---:|---:|---:|
| trip_routing vs OSRM | 0.997 (0.995–0.998) | 0.977–0.999 | 86% | 93% |
| trip_routing vs Valhalla | 0.989 (0.982–0.993) | 0.951–1.000 | 76% | 87% |
| OSRM vs Valhalla, for reference | 0.999 (0.996–1.000) | 0.962–1.010 | 73% | 86% |

trip_routing's routes are as long as OSRM's (0.3% shorter at the median) and agree with OSRM more closely than OSRM and Valhalla agree with each other. The routes also follow the same streets: a median 91% of a trip_routing route runs within 20 m of OSRM's route (OSRM and Valhalla: 74%). Where trip_routing is longer than OSRM by more than 1% in its shortest-path mode (11 of 400 trips), OSRM either started on a different way crossing at another level (a bridge or underpass) or crossed a pedestrian square that trip_routing does not route across.

**Routing time**:

| | Median | 95th percentile | Note |
|---|---:|---:|---|
| trip_routing | 0.66 ms | 5.8 ms | in the app, no network |
| OSRM, local server | 0.20 ms | 0.31 ms | server-side time; 0.42 ms including local HTTP |
| Valhalla, public server | 92 ms | | including the network round trip from Germany |

OSRM's precomputed contraction hierarchies answer each query faster than trip_routing's on-the-fly search, at the cost of a server and preprocessing: 3.6 minutes, 2.4 GB of memory and about 1 GB of disk for the Cologne region that contains Aachen. trip_routing prepares a city in under a second once the data is downloaded, and any routing server adds a network round trip that is tens to hundreds of times longer than either engine's computation.

Google Maps was not part of the comparison because its API requires a billing account.

### Known limitations

- Waypoints snap to the geometrically nearest walkable way. For a point deep inside a large building this can be a poor entry point; use `replaceWaypointsWithBuildingEntrances` for such points.
- Pedestrian squares mapped as areas (`area=yes`) are walked around rather than across.
- The public Overpass server is shared and sometimes overloaded. Requests are retried, but for production apps consider [your own Overpass instance or fallbacks](#networking) and offline cities.

---

## Privacy

Routing itself runs on the device, but map data comes from the public Overpass API, which sees what is requested:

| Mode | What the map server learns about your waypoints |
|---|---|
| Online, default (`RoutingPrivacy.standard`) | Their exact positions: the requested area is the waypoints plus a predictable margin, and building-entrance lookups send the exact coordinates. |
| Online, `RoutingPrivacy.area` | Only which cells of a fixed ~1 km grid they lie in. Any waypoints in the same cells send identical requests. No entrance lookups. Downloads about 3x as much map data (median, measured in Aachen). |
| Offline (`useCity`) | Nothing. Only the city name is sent once, when the city is downloaded. Entrance lookups are skipped. |

```dart
final routing = TripService(privacy: RoutingPrivacy.area);
// or per request:
await routing.findTotalTrip(waypoints, privacy: RoutingPrivacy.area);
```

Use `privacyCellDegrees` to change the cell size (default `0.01`, about 1.1 km). In every mode the servers see your IP address and when requests are made; use your own Overpass instance (see below) if that matters.

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
