@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

/// Integration tests against the live Overpass/Nominatim APIs.
/// Excluded from CI; run with `flutter test --tags network`.
void main() {
  final waypoints = [
    const LatLng(50.77437074991441, 6.075419266272186),
    const LatLng(50.774717242584515, 6.083980842518867),
  ];

  test('findTotalTrip (online) returns a route with distance', () async {
    final trip = await TripService().findTotalTrip(
      waypoints,
      replaceWaypointsWithBuildingEntrances: true,
    );
    expect(trip.errors, isEmpty);
    expect(trip.route, isNotEmpty);
    expect(trip.distance, greaterThan(0));
    // Snapping puts the route ends on the way next to the waypoints.
    expect(
        haversineDistance(trip.route.last.latitude, trip.route.last.longitude,
            waypoints.last.latitude, waypoints.last.longitude),
        lessThan(100));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('useCity (offline) routes within Aachen', () async {
    final routing = TripService();
    expect(await routing.useCity('Aachen'), isTrue);
    final trip = await routing.findTotalTrip(waypoints);
    expect(trip.errors, isEmpty);
    expect(trip.route, isNotEmpty);
    expect(trip.distance, greaterThan(0));
    expect(File('Aachen.trg').existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
