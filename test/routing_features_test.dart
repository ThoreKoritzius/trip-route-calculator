import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

import 'fixtures.dart';

TripService _offline(Graph graph, {http.Client? client}) => TripService(
    osmClient: OsmClient(
        client: client ??
            MockClient((_) => throw StateError('unexpected network use')),
        retryDelay: Duration.zero))
  ..graph = graph
  ..currentCity = 'Fixture';

double _dist(LatLng a, LatLng b) =>
    haversineDistance(a.latitude, a.longitude, b.latitude, b.longitude);

class _TempCityService extends TripService {
  final Directory dir;
  _TempCityService(this.dir, http.Client client)
      : super(osmClient: OsmClient(client: client, retryDelay: Duration.zero));

  @override
  Future<String> getCityPath(String cityName) async =>
      '${dir.path}/$cityName.json';
}

void main() {
  final graph = buildGraphFromOsmElements(fixture);

  group('snapping to the nearest point on a way', () {
    test('projects waypoints onto the segment instead of the nearest node', () {
      // ~11 m south of the middle of segment 1-2.
      final snap = snapToGraph(graph, const LatLng(49.9999, 6.0005))!;
      expect(snap.point.latitude, closeTo(50.0, 1e-9));
      expect(snap.point.longitude, closeTo(6.0005, 1e-9));
      expect(snap.distance, closeTo(11.1, 0.2));
      expect(snap.fraction, closeTo(0.5, 1e-6));
    });

    test('routes start and end on the road next to the waypoints', () async {
      final trip = await _offline(graph).findTotalTrip(
          [const LatLng(49.9999, 6.0005), const LatLng(49.9999, 6.0035)],
          preferWalkingPaths: false);
      expect(trip.errors, isEmpty);
      expect(trip.route.first.longitude, closeTo(6.0005, 1e-9));
      // Node 6 is 5 cm off the line, so the projection shifts very slightly.
      expect(trip.route.last.longitude, closeTo(6.0035, 1e-6));
      // 0.003 degrees of longitude at 50° N ≈ 214 m.
      expect(trip.distance, closeTo(214.5, 1.5));
    });

    test('two waypoints on the same segment walk along it directly', () async {
      final trip = await _offline(graph).findTotalTrip(
          [const LatLng(50.0, 6.0002), const LatLng(50.0, 6.0008)],
          preferWalkingPaths: false);
      expect(trip.errors, isEmpty);
      expect(
          trip.route, [const LatLng(50.0, 6.0002), const LatLng(50.0, 6.0008)]);
      expect(trip.distance, closeTo(42.9, 0.5));
    });

    test('rejects waypoints far from the network but routes the rest',
        () async {
      final trip = await _offline(graph).findTotalTrip([
        pos(graph, 1),
        pos(graph, 7),
        const LatLng(50.1, 6.0), // ~11 km away
      ]);
      expect(trip.errors, hasLength(1));
      expect(trip.errors.single, startsWith('Waypoint 3 is'));
      expect(trip.route.first, pos(graph, 1));
      expect(trip.route.last, pos(graph, 7));
    });

    test('maxSnapDistance is configurable', () async {
      final trip = await _offline(graph).findTotalTrip(
          [const LatLng(49.9999, 6.0005), pos(graph, 7)],
          maxSnapDistance: 5);
      expect(trip.errors.single, startsWith('Waypoint 1 is 11 m'));
      expect(trip.route, isEmpty);
    });
  });

  group('forceIncludeWaypoints', () {
    test('counts the off-network connectors in the distance', () async {
      const start = LatLng(49.9999, 6.0005);
      const end = LatLng(49.9999, 6.0035);
      final service = _offline(graph);
      final plain =
          await service.findTotalTrip([start, end], preferWalkingPaths: false);
      final forced = await service.findTotalTrip([start, end],
          preferWalkingPaths: false, forceIncludeWaypoints: true);
      expect(forced.route.first, start);
      expect(forced.route.last, end);
      expect(
          forced.distance,
          closeTo(
              plain.distance +
                  _dist(start, plain.route.first) +
                  _dist(plain.route.last, end),
              0.01));
    });

    test('intermediate waypoints count the detour there and back', () async {
      const middle = LatLng(49.9999, 6.002); // ~11 m south of node 3
      final waypoints = [pos(graph, 1), middle, pos(graph, 7)];
      final service = _offline(graph);
      final plain =
          await service.findTotalTrip(waypoints, preferWalkingPaths: false);
      final forced = await service.findTotalTrip(waypoints,
          preferWalkingPaths: false, forceIncludeWaypoints: true);
      expect(forced.route, contains(middle));
      expect(forced.distance,
          closeTo(plain.distance + 2 * _dist(middle, pos(graph, 3)), 0.01));
    });
  });

  group('cost model', () {
    test('footwayCostFactor controls the walking preference', () async {
      final service = _offline(graph);
      final waypoints = [pos(graph, 1), pos(graph, 3)];
      final strong = await service.findTotalTrip(waypoints);
      expect(strong.route, contains(pos(graph, 4)));
      final none =
          await service.findTotalTrip(waypoints, footwayCostFactor: 1.0);
      expect(none.route, contains(pos(graph, 2)));
    });

    test('avoidSteps detours around stairs', () {
      // 1 -> 3 directly via steps (143 m) or via a 4-node road (~300 m).
      final stairs = buildGraphFromOsmElements([
        osmNode(1, 50.0, 6.0),
        osmNode(2, 50.0, 6.002),
        osmNode(3, 50.001, 6.0),
        osmNode(4, 50.001, 6.002),
        osmWay(10, [1, 2], 'steps'),
        osmWay(11, [1, 3, 4, 2], 'residential'),
      ]);
      final start = GraphSnap.atNode(stairs.nodes[1]!);
      final end = GraphSnap.atNode(stairs.nodes[2]!);
      final direct = routeBetween(stairs, start, end, const RouteCosts())!;
      expect(direct.route, hasLength(2));
      final detour =
          routeBetween(stairs, start, end, const RouteCosts(avoidSteps: true))!;
      expect(detour.route, hasLength(4));
    });

    test('excludes private and foot=no ways, keeps foot=yes overrides', () {
      Map<String, dynamic> way(
              int id, List<int> nodes, Map<String, String> t) =>
          {'type': 'way', 'id': id, 'nodes': nodes, 'tags': t};
      final g = buildGraphFromOsmElements([
        osmNode(1, 50.0, 6.0),
        osmNode(2, 50.0, 6.001),
        osmNode(3, 50.0, 6.002),
        osmNode(4, 50.0, 6.003),
        osmNode(5, 50.0, 6.004),
        way(10, [1, 2], {'highway': 'service', 'access': 'no', 'foot': 'yes'}),
        way(11, [2, 3], {'highway': 'residential'}),
        way(12, [3, 4], {'highway': 'service', 'access': 'private'}),
        way(13, [4, 5], {'highway': 'path', 'foot': 'no'}),
      ], minIslandSize: 0);
      expect(g.adjacencyList[1]!.map((e) => e.to), [2]);
      expect(g.adjacencyList[3]!.map((e) => e.to), [2]);
      expect(g.adjacencyList[4], isEmpty);
    });
  });

  group('offline mode', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('trip_routing'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('cache stores download time and stairs', () async {
      final g = buildGraphFromOsmElements([
        osmNode(1, 50.0, 6.0),
        osmNode(2, 50.0, 6.001),
        osmWay(10, [1, 2], 'steps'),
      ])
        ..createdAt = DateTime.utc(2026, 1, 2);
      await g.saveGraph('${dir.path}/g.json');
      final loaded = await Graph.fromFile('${dir.path}/g.json');
      expect(loaded.createdAt, DateTime.utc(2026, 1, 2));
      expect(loaded.adjacencyList[1]!.single.isSteps, isTrue);
    });

    Future<void> writeCache(DateTime? createdAt) =>
        (buildGraphFromOsmElements(fixture)..createdAt = createdAt)
            .saveGraph('${dir.path}/Fixture.json');

    test('useCity(maxAge) keeps a fresh cache without network', () async {
      await writeCache(DateTime.now().toUtc());
      final service = _TempCityService(
          dir, MockClient((_) => throw StateError('network used')));
      expect(await service.useCity('Fixture', maxAge: const Duration(days: 30)),
          isTrue);
    });

    test('useCity(maxAge) refreshes a stale cache', () async {
      await writeCache(DateTime.utc(2020));
      final requests = <String>[];
      final service = _TempCityService(dir, MockClient((r) async {
        final response = await fixtureHandler(r);
        requests.add('${r.url.host} ${response.statusCode}');
        return response;
      }));
      expect(await service.useCity('Fixture', maxAge: const Duration(days: 30)),
          isTrue);
      expect(
          requests, ['nominatim.openstreetmap.org 200', 'overpass-api.de 200']);
      final refreshed = await Graph.fromFile('${dir.path}/Fixture.json');
      expect(refreshed.createdAt!.year, greaterThanOrEqualTo(2026));
    });

    test('useCity(maxAge) falls back to a stale cache when offline', () async {
      await writeCache(null); // legacy file without timestamp
      final service = _TempCityService(
          dir, MockClient((_) => throw const SocketException('offline')));
      expect(await service.useCity('Fixture', maxAge: const Duration(days: 30)),
          isTrue);
      expect(service.graph.nodes, isNotEmpty);
    });

    test('never looks up entrances (or uses the network) offline', () async {
      var requests = 0;
      final service = _offline(graph, client: MockClient((_) async {
        requests++;
        return http.Response('{"elements": []}', 200);
      }));
      final trip = await service.findTotalTrip(
          [const LatLng(49.9998, 5.9998), pos(graph, 7)],
          replaceWaypointsWithBuildingEntrances: true);
      expect(trip.errors, isEmpty);
      expect(requests, 0);
    });
  });

  group('useCity failure reasons', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('trip_routing'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<(bool, String?)> load(
        Future<http.Response> Function(http.Request) handler) async {
      final service = _TempCityService(dir, MockClient(handler));
      final ok = await service.useCity('Fixture');
      return (ok, service.lastCityError);
    }

    test('reports unknown cities', () async {
      expect(await load((_) async => http.Response('[]', 200)),
          (false, 'City "Fixture" not found.'));
    });

    test('reports a busy Overpass server after retries', () async {
      final (ok, error) = await load((r) async =>
          r.url.host.contains('nominatim')
              ? fixtureHandler(r)
              : http.Response('busy', 504));
      expect(ok, isFalse);
      expect(error, 'Overpass request failed with HTTP 504 (server busy)');
    });

    test('reports cities without walkable ways', () async {
      final (ok, error) = await load((r) async =>
          r.url.host.contains('nominatim')
              ? fixtureHandler(r)
              : http.Response('{"elements": []}', 200));
      expect(ok, isFalse);
      expect(error, 'No walkable ways found for "Fixture".');
    });

    test('is cleared on success and kept when falling back to a stale cache',
        () async {
      final service = _TempCityService(dir, MockClient(fixtureHandler));
      service.lastCityError = 'old';
      expect(await service.useCity('Fixture'), isTrue);
      expect(service.lastCityError, isNull);

      final offline = _TempCityService(
          dir, MockClient((_) async => http.Response('busy', 429)));
      expect(await offline.useCity('Fixture', maxAge: Duration.zero), isTrue);
      expect(offline.lastCityError, contains('429'));
    });
  });

  group('OsmClient retries', () {
    OsmClient client(List<http.Response> responses, List<Uri> seen,
            {List<String> fallbacks = const []}) =>
        OsmClient(
            retryDelay: Duration.zero,
            fallbackOverpassUrls: fallbacks,
            client: MockClient((r) async {
              seen.add(r.url);
              return responses.removeAt(0);
            }));
    final ok = http.Response('{"elements": [1]}', 200);

    test('retries busy servers and succeeds', () async {
      final seen = <Uri>[];
      final osm = client([
        http.Response('busy', 504),
        http.Response('slow down', 429, headers: {'retry-after': '0'}),
        ok,
      ], seen);
      expect(await osm.overpass('q'), [1]);
      expect(seen, hasLength(3));
    });

    test('retries runtime-error remarks', () async {
      final seen = <Uri>[];
      final osm = client([
        http.Response(
            '{"elements": [], "remark": "runtime error: timeout"}', 200),
        ok,
      ], seen);
      expect(await osm.overpass('q'), [1]);
    });

    test('does not retry client errors', () async {
      final seen = <Uri>[];
      final osm = client([http.Response('bad query', 400), ok], seen);
      await expectLater(osm.overpass('q'), throwsA(isA<OsmRequestException>()));
      expect(seen, hasLength(1));
    });

    test('moves on to fallback instances', () async {
      final seen = <Uri>[];
      final osm = client([http.Response('', 504), ok], seen,
          fallbacks: ['https://mirror.example/api/interpreter']);
      await osm.overpass('q');
      expect(seen.map((u) => u.host), ['overpass-api.de', 'mirror.example']);
    });

    test('per-request retry override', () async {
      final seen = <Uri>[];
      final osm = client([http.Response('', 504), ok], seen);
      await expectLater(osm.overpass('q', maxRetries: 0),
          throwsA(isA<OsmRequestException>()));
      expect(seen, hasLength(1));
    });
  });
}
