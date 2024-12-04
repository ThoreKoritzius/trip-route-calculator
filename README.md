## Routing Trip Planner
Flutter on-device trip-routing calculator package for multiple waypoints, optimized for food traffic. This package uses overpass api to fetch all ways inside bounding box of your points and provides a detailed polyline route containing a list of LatLng points.

### Example

```dart
final testPoints = [
    LatLng(50.77437074991441, 6.075419266272186),
    LatLng(50.778183576682636, 6.088382934817764)
];

final routing = TripService();
try {
    final trip = await routing.findTotalTrip(testPoints, preferWalkingPaths: true);
    print('Route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
} catch (e) {
    print('Error calculating route: $e');
}
```