import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';

void main() async {
  final waypoints = [
    const LatLng(50.77437074991441, 6.075419266272186),
    const LatLng(50.774717242584515, 6.083980842518867),
  ];

  final routing = TripService();
  await routing.useCity('Aachen'); //make routing available offline

  try {
    final trip = await routing.findTotalTrip(waypoints,
        preferWalkingPaths: true, replaceWaypointsWithBuildingEntrances: true);
    print('Calculated route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
    print('Errors: ${trip.errors}');
  } catch (e) {
    print('Error calculating route: $e');
  }
}
