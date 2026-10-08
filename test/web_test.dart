@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

import 'fixtures.dart';

/// Runs in a real browser: `flutter test --platform chrome test/web_test.dart`.
void main() {
  test('useCity keeps the city in memory and routes on the web', () async {
    final service = TripService(
        osmClient: OsmClient(
            client: MockClient(fixtureHandler), retryDelay: Duration.zero));
    expect(await service.useCity('Fixture'), isTrue);
    final trip = await service
        .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
    expect(trip.errors, isEmpty);
    expect(trip.distance, greaterThan(250));
  });

  test('file access reports that it is unsupported', () async {
    await expectLater(
        Graph.fromFile('x.json'), throwsA(isA<UnsupportedError>()));
  });
}
