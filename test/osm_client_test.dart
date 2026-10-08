import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

OsmClient _client(FutureOr<http.Response> Function(http.Request) handler,
        {Duration timeout = const Duration(seconds: 90)}) =>
    OsmClient(client: MockClient((r) async => handler(r)), timeout: timeout);

void main() {
  group('OsmClient.overpass', () {
    test('sends the query as form data with a User-Agent', () async {
      late http.Request sent;
      final osm = _client((r) {
        sent = r;
        return http.Response('{"elements": []}', 200);
      });
      await osm.fetchWalkableWays(1, 2, 3, 4);
      expect(sent.method, 'POST');
      expect(sent.headers['User-Agent'], OsmClient.defaultUserAgent);
      final query = sent.bodyFields['data']!;
      expect(query, contains('(1.0,2.0,3.0,4.0)'));
      expect(query, contains('[timeout:90]'));
      expect(query, contains('motorway'));
    });

    test('throws OsmRequestException on non-JSON bodies', () async {
      final osm =
          _client((_) => http.Response('<html>Gateway Timeout</html>', 200));
      await expectLater(osm.overpass('q'), throwsA(isA<OsmRequestException>()));
    });

    test('throws on runtime-error remarks instead of using partial data',
        () async {
      final osm = _client((_) => http.Response(
          jsonEncode({
            'elements': [],
            'remark': 'runtime error: Query timed out in "query" at line 3',
          }),
          200));
      await expectLater(
          osm.overpass('q'),
          throwsA(isA<OsmRequestException>()
              .having((e) => e.message, 'message', contains('timed out'))));
    });

    test('throws on HTTP errors and timeouts', () async {
      await expectLater(_client((_) => http.Response('', 504)).overpass('q'),
          throwsA(isA<OsmRequestException>()));
      final slow = _client((_) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.Response('{"elements": []}', 200);
      }, timeout: const Duration(milliseconds: 10));
      await expectLater(
          slow.overpass('q'), throwsA(isA<OsmRequestException>()));
    });
  });

  group('OsmClient.fetchCityBounds', () {
    test('URL-encodes the city and reorders Nominatim bounds', () async {
      late Uri uri;
      final osm = _client((r) {
        uri = r.url;
        return http.Response(
            jsonEncode([
              {
                'boundingbox': ['-23.8', '-23.3', '-46.8', '-46.3']
              }
            ]),
            200);
      });
      final bounds = await osm.fetchCityBounds('São Paulo & Co');
      expect(uri.queryParameters['city'], 'São Paulo & Co');
      expect(uri.toString(), isNot(contains(' ')));
      expect(bounds, [-23.8, -46.8, -23.3, -46.3]);
    });

    test('returns null for unknown cities and malformed boxes', () async {
      expect(
          await _client((_) => http.Response('[]', 200)).fetchCityBounds('x'),
          isNull);
      expect(
          await _client((_) => http.Response(
              jsonEncode([
                {
                  'boundingbox': ['a', 'b']
                }
              ]),
              200)).fetchCityBounds('x'),
          isNull);
    });

    test('throws OsmRequestException on non-JSON bodies', () async {
      await expectLater(
          _client((_) => http.Response('Access blocked', 200))
              .fetchCityBounds('x'),
          throwsA(isA<OsmRequestException>()));
    });
  });

  group('TripService error handling', () {
    test('findTotalTrip reports a non-JSON Overpass response', () async {
      final service = TripService(
          httpClient: MockClient((_) async => http.Response('<html/>', 200)));
      final trip = await service
          .findTotalTrip([const LatLng(50, 6), const LatLng(50, 6.004)]);
      expect(trip.route, isEmpty);
      expect(trip.errors.single, startsWith('Graph data unavailable'));
    });

    test('useCity returns false on a non-JSON Nominatim response', () async {
      final service = TripService(
          httpClient: MockClient((_) async => http.Response('blocked', 200)));
      expect(
          await service
              .useCity('Nowhere-${DateTime.now().millisecondsSinceEpoch}'),
          isFalse);
      expect(service.currentCity, isNull);
    });
  });
}
