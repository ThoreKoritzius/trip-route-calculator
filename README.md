## Routing Trip Planner
Flutter on-device trip-routing calculator package for multiple waypoints, optimized for pedestrian navigation. This package uses overpass api to fetch all ways inside bounding box of your waypoints and provides a detailed polyline route containing a list of LatLng points.

### Getting started
Add this to your package's `pubspec.yaml` file:
```
dependencies:
  trip_routing: ^0.0.5
```

### Example

```dart
final waypoints = [
    const LatLng(50.77437074991441, 6.075419266272186),
    const LatLng(50.778183576682636, 6.088382934817764)
];

final routing = TripService();
try {
    final trip = await routing.findTotalTrip(waypoints, preferWalkingPaths: true);
    print('Calculated route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
    print('Errors: ${trip.errors}');
} catch (e) {
    print('Error calculating route: $e');
}
```


### Package Link
Find the flutter package at
https://pub.dev/packages/trip_routing


### Repo Link
Find the code repo at
https://github.com/ThoreKoritzius/trip-route-calculator