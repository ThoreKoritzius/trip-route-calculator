
import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';

void main() async {
  final testPoints = [
    LatLng(50.77437074991441, 6.075419266272186),
    LatLng(50.778183576682636, 6.088382934817764)
  ];

  // Initialize Routing Service
  final routing = TripService();
  try {
    final trip = await routing.findTotalTrip(testPoints, preferWalkingPaths: true);
    print('Route: ${trip.route}');
    print('Distance: ${trip.distance} meters');
  } catch (e) {
    print('Error calculating route: $e');
  }
}
