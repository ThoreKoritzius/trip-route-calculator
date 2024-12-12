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
- **`replaceWaypointsWithBuildingEntrances`** *(bool)*: Whether to replace waypoints with building entrances, if available. Default: `false`.
- **`forceIncludeWaypoints`** *(bool)*: Whether to force the inclusion of waypoints in the final route, even if they are not on a road. Default: `false`.
- **`duplicationPenalty`** *(double?)*: Penalty term to discourage duplicate paths in the route. Default: `null`.

---

## Offline Routing

You can save routing data on disk for a specific city to enable offline routing. To initialize offline routing, call the `useCity` function:

```dart
final routing = TripService();
await routing.useCity('Aachen');
```

This will fetch and store routing information for the specified city on first use, ensuring fast subsequent routing even without internet access.

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

## Contributing

We welcome contributions! Feel free to open issues or submit pull requests to improve the package.

For major changes, please open an issue first to discuss what you would like to change.
