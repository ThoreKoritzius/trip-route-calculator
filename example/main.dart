import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';

void main() async {
  final waypoints = [
    const LatLng(50.77437074991441, 6.075419266272186),
    const LatLng(50.778183576682636, 6.088382934817764)
  ];

  final routing = TripService();
  try {
    final trip =
        await routing.findTotalTrip(waypoints, preferWalkingPaths: true);
    print('Calculated route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
    print('Errors: ${trip.errors}');
  } catch (e) {
    print('Error calculating route: $e');
  }
}
