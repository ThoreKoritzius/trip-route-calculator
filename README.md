## Routing Trip Planner
Flutter client-side trip-routing calculator package for multiple waypoints, optimized for pedestrian navigation. This package uses overpass api to fetch all ways inside bounding box of your waypoints and calculates an optimal route between them. A detailed polyline route containing a list of LatLng points is returned.

### Getting started
Add this to your package's `pubspec.yaml` file:
```
dependencies:
  trip_routing: <lastest>
```

### Example

```dart
final waypoints = [
    const LatLng(50.77437074991441, 6.075419266272186),
    const LatLng(50.774717242584515, 6.083980842518867),
];

final routing = TripService();
try {
    final trip = await routing.findTotalTrip(waypoints,
        preferWalkingPaths: true, replaceWaypointsWithBuildingEntrances: true);
    print('Calculated route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
    print('Errors: ${trip.errors}');
} catch (e) {
    print('Error calculating route: $e');
}
```
`findTotalTrip` arguments
  - **waypoints**: A list of `LatLng` objects representing the locations (latitude and longitude)
     between which the route needs to be calculated.
  - **preferWalkingPaths**: Bool flag indicating whether walking paths should be preferred
     over other types of paths. Defaults to `true`.
  - **replaceWaypointsWithBuildingEntrances**: Boolean flag that determines if waypoints should
     be replaced with building entrances. Defaults to `false`.
  - **forceIncludeWaypoints**: Boolean flag that forces the inclusion of waypoints in the final
     route even if they are not exactly on a road. Defaults to `false`.


### Package Link
Find the flutter package at
https://pub.dev/packages/trip_routing


### Repo Link
Find the code repo at
https://github.com/ThoreKoritzius/trip-route-calculator