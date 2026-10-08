import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

/// Runs an online findTotalTrip and returns every request body sent upstream.
Future<List<String>> _requests(List<LatLng> waypoints,
    {RoutingPrivacy privacy = RoutingPrivacy.area,
    bool entrances = true}) async {
  final sent = <String>[];
  final service = TripService(
      privacy: privacy,
      onlineCacheDuration: Duration.zero,
      osmClient: OsmClient(
          maxRetries: 0,
          client: MockClient((r) async {
            sent.add(r.bodyFields['data'] ?? r.url.toString());
            return http.Response('{"elements": []}', 200);
          })));
  await service.findTotalTrip(waypoints,
      replaceWaypointsWithBuildingEntrances: entrances);
  return sent;
}

/// Bounds requested by a roads query, as `[minLat, minLon, maxLat, maxLon]`.
List<double> _bbox(String query) {
  final m = RegExp(r'\(([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)\);')
      .firstMatch(query)!;
  return [for (var i = 1; i <= 4; i++) double.parse(m.group(i)!)];
}

/// The attack from the privacy analysis: undo the standard padding and take
/// the box corners as the waypoint candidates.
List<LatLng> _attack(List<double> b) {
  List<double> unpad(double lo, double hi) {
    final inner = (hi - lo) / 1.6;
    final pad = inner * 0.3 >= 0.005 ? inner * 0.3 : 0.005;
    return [lo + pad, hi - pad];
  }

  final lat = unpad(b[0], b[2]), lon = unpad(b[1], b[3]);
  return [
    for (final a in lat)
      for (final o in lon) LatLng(a, o)
  ];
}

double _dist(LatLng a, LatLng b) =>
    haversineDistance(a.latitude, a.longitude, b.latitude, b.longitude);

void main() {
  final random = Random(5);
  (LatLng, LatLng) randomTrip() {
    final s = LatLng(
        50.75 + random.nextDouble() * 0.05, 6.05 + random.nextDouble() * 0.05);
    return (
      s,
      LatLng(s.latitude + (random.nextDouble() - 0.5) * 0.04,
          s.longitude + (random.nextDouble() - 0.5) * 0.06)
    );
  }

  test('standard mode reveals the waypoints (documents the baseline)',
      () async {
    var located = 0;
    for (var i = 0; i < 50; i++) {
      final (start, end) = randomTrip();
      final sent = await _requests([start, end],
          privacy: RoutingPrivacy.standard, entrances: false);
      final candidates = _attack(_bbox(sent.single));
      if (candidates.any((c) => _dist(c, start) < 1) &&
          candidates.any((c) => _dist(c, end) < 1)) {
        located++;
      }
    }
    expect(located, 50);
  });

  group('RoutingPrivacy.area', () {
    test('sends no coordinates, only one grid-aligned area', () async {
      final (start, end) = randomTrip();
      final sent = await _requests([start, end]);
      expect(sent, hasLength(1)); // no entrance lookup
      expect(sent.single, isNot(contains('around')));
      expect(_bbox(sent.single),
          findGridBounds([start, end], minPaddingDegrees: 0.005));
    });

    test('waypoints anywhere in the same cells send identical requests',
        () async {
      const cellLat = 0.01, cellLon = 0.015;
      for (var i = 0; i < 40; i++) {
        final (start, end) = randomTrip();
        // Another random position in the same grid cell.
        LatLng sameCell(LatLng p) => LatLng(
            ((p.latitude / cellLat).floor() + random.nextDouble()) * cellLat,
            ((p.longitude / cellLon).floor() + random.nextDouble()) * cellLon);
        final a = await _requests([start, end]);
        final b = await _requests([sameCell(start), sameCell(end)]);
        expect(b, a);
      }
    });

    test('the standard-mode attack no longer locates waypoints', () async {
      var near = 0;
      for (var i = 0; i < 100; i++) {
        final (start, end) = randomTrip();
        final candidates =
            _attack(_bbox((await _requests([start, end])).single));
        if (candidates.any((c) => _dist(c, start) < 50)) near++;
        if (candidates.any((c) => _dist(c, end) < 50)) near++;
      }
      // Only chance hits remain (a 50 m disc covers ~0.6% of a 1 km cell).
      expect(near, lessThan(10));
    });

    test('still routes and covers every waypoint', () async {
      final service = TripService(
          privacy: RoutingPrivacy.area,
          osmClient: OsmClient(
              client: MockClient((r) async => http.Response(
                  '{"elements": [${_line(50.0, 6.0, 50.0, 6.004)}]}', 200))));
      final trip = await service.findTotalTrip(
          [const LatLng(50.0, 6.0005), const LatLng(50.0, 6.0035)]);
      expect(trip.errors, isEmpty);
      expect(trip.distance, closeTo(214.5, 1));
      final b = trip.boundingBox!;
      expect(
          b[0] < 50.0 && b[2] > 50.0 && b[1] < 6.0005 && b[3] > 6.0035, isTrue);
    });

    test('can be chosen per call', () async {
      final (start, end) = randomTrip();
      final standard = await _requests([start, end],
          privacy: RoutingPrivacy.standard, entrances: true);
      expect(standard.where((q) => q.contains('around')), isNotEmpty);

      final sent = <String>[];
      final service = TripService(
          onlineCacheDuration: Duration.zero,
          osmClient: OsmClient(
              maxRetries: 0,
              client: MockClient((r) async {
                sent.add(r.bodyFields['data']!);
                return http.Response('{"elements": []}', 200);
              })));
      await service.findTotalTrip([start, end],
          replaceWaypointsWithBuildingEntrances: true,
          privacy: RoutingPrivacy.area);
      expect(sent.where((q) => q.contains('around')), isEmpty);
    });
  });

  test('findGridBounds depends only on cells and pads like standard mode', () {
    final b = findGridBounds([const LatLng(50.7741, 6.0868)]);
    // Cell [50.77, 50.78] x [6.075, 6.09], padded by 0.005 on each side.
    expect(b, [50.765, 6.07, 50.785, 6.095]);
    expect(findGridBounds([const LatLng(50.7799, 6.0751)]), b);
  });
}

/// A straight residential way between two points, as Overpass elements.
String _line(double lat1, double lon1, double lat2, double lon2) =>
    '{"type":"node","id":1,"lat":$lat1,"lon":$lon1},'
    '{"type":"node","id":2,"lat":$lat2,"lon":$lon2},'
    '{"type":"way","id":3,"nodes":[1,2],"tags":{"highway":"residential"}}';
