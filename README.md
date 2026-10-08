# Trip Route Calculator

**trip_routing** is a Flutter package designed for client-side trip routing with multiple waypoints, optimized for pedestrian navigation. It uses the Overpass API to fetch all relevant paths within a bounding box of your waypoints and calculates an optimal route between them. The output is a detailed polyline route containing a list of `LatLng` points, allowing a seamless integration into Flutter map applications.

This package is production-ready and powers the AI travel app [Worldbummlr](https://worldbummlr.com?ref=trip_routing).

---

## Key Features

- **Client-side routing**: Perform routing directly on the client without external dependencies.
- **Offline capability**: Cache routing data for specific cities for offline use.
- **Fetch building entrances**: Enhance pedestrian path precision by automatically fetching building entrances for waypoints associated with buildings.
- **Optimized for pedestrians**: Prefers walking paths and pedestrian-friendly routes.
- **Customizable routing**: Fine-tune routing preferences such as including duplicate paths or forcing waypoint inclusion.

---

## Installation

Add the package to your Flutter app by including the following in your `pubspec.yaml` file:

```yaml
dependencies:
  trip_routing: <latest>
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
try {
    final trip = await routing.findTotalTrip(
        waypoints,
        preferWalkingPaths: true,
        replaceWaypointsWithBuildingEntrances: true,
    );
    print('Calculated route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
    print('Errors: ${trip.errors}');
} catch (e) {
    print('Error calculating route: $e');
}
```

### `findTotalTrip` Parameters

- **`waypoints`** *(List\<LatLng\>)*: Locations (latitude and longitude) between which the route is calculated.
- **`preferWalkingPaths`** *(bool)*: Whether to prioritize walking paths over other types of paths. Default: `true`.
- **`replaceWaypointsWithBuildingEntrances`** *(bool)*: Whether to replace waypoints with building entrances, if available. Sends the exact waypoints to Overpass, so it only applies online in the default privacy mode. Default: `false`.
- **`forceIncludeWaypoints`** *(bool)*: Whether to force the inclusion of waypoints in the final route, even if they are not on a road. Default: `false`.
- **`duplicationPenalty`** *(double)*: Penalty (in meters) added whenever an edge already used by a previous leg is reused, to discourage out-and-back routes. Default: `0.0`.
- **`footwayCostFactor`** *(double)*: Cost multiplier for dedicated walking ways when `preferWalkingPaths` is set; lower values prefer them more strongly. Default: `0.9`.
- **`avoidSteps`** *(bool)*: Make stairs 5x as expensive, e.g. for wheelchair or stroller routes. Default: `false`.
- **`privacy`** *(RoutingPrivacy?)*: What the map server may learn about the waypoints, see [Privacy](#privacy). Default: the service's `privacy` (`standard`).
- **`maxSnapDistance`** *(double)*: Waypoints are snapped to the closest point on a walkable way; waypoints further away than this (in meters) are reported in `errors`. Default: `1000`.

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
      '${(await getApplicationSupportDirectory()).path}/$cityName.json';
}
```

Pass `maxAge` to refresh outdated data (the stale cache is still used if the refresh fails):

```dart
await routing.useCity('Aachen', maxAge: const Duration(days: 30));
```

On the web there is no file system, so the city data is kept in memory only.

Call `routing.useOnlineData()` to switch back to fetching live data around the waypoints.

## Performance

Online requests fetch roads and building entrances in parallel. The fetched area is reused for 10 minutes for later requests inside it (configurable via `TripService(onlineCacheDuration: ...)`), and successful entrance lookups are cached, so repeated or nearby requests need no network at all.

Routing uses A* search and a spatial index for snapping waypoints. Measured on the city of Aachen (209k nodes, MacBook, `dart run benchmark/benchmark.dart`):

| | 0.0.14 | before |
|---|---|---|
| Load offline city | 88 ms, 11 MB file, +110 MB RAM | 423 ms, 43 MB file, +456 MB RAM |
| Route 900 m | 0.7 ms | 37 ms |
| Route 21 km across the city | 85 ms | 229 ms |
| Route with 10 waypoints | 0.5 ms | 172 ms |
| Repeated online request | ~1 ms (cached) | full download (5–30 s) |

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

## Example Output

The route calculation returns the following:

- **`route`** *(List\<LatLng\>)*: A list of points forming the route.
- **`distance`** *(double)*: The total distance of the route in meters.
- **`errors`** *(List<String>?)*: Any errors encountered during routing.

---

## Where to Find More

- **Flutter Package**: [trip_routing on pub.dev](https://pub.dev/packages/trip_routing)
- **GitHub**: [https://github.com/ThoreKoritzius/trip-route-calculator](https://github.com/ThoreKoritzius/trip-route-calculator)

---

## Development

```bash
flutter test                      # offline unit tests (HTTP is mocked)
flutter test --tags network       # live Overpass/Nominatim integration tests
```

## Contributing

We welcome contributions! Feel free to open issues or submit pull requests to improve the package.

For major changes, please open an issue first to discuss what you would like to change.
