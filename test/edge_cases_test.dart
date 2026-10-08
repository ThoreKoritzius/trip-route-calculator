import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';

import 'fixtures.dart';

/// A square building from (50.0, 6.0) to (50.001, 6.001) with outline nodes
/// 20..23, plus the given entrance nodes.
Map<String, dynamic> _buildingResponse(List<Map<String, dynamic>> entrances) =>
    {
      'elements': [
        {
          'type': 'way',
          'id': 1,
          'nodes': [20, 21, 22, 23, 20],
          'tags': {'building': 'yes'},
          'bounds': {
            'minlat': 50.0,
            'minlon': 6.0,
            'maxlat': 50.001,
            'maxlon': 6.001
          },
          'geometry': [
            {'lat': 50.0, 'lon': 6.0},
            {'lat': 50.0, 'lon': 6.001},
            {'lat': 50.001, 'lon': 6.001},
            {'lat': 50.001, 'lon': 6.0},
            {'lat': 50.0, 'lon': 6.0},
          ],
        },
        ...entrances,
      ],
    };

Map<String, dynamic> _entrance(int id, double lat, double lon, String kind) => {
      'type': 'node',
      'id': id,
      'lat': lat,
      'lon': lon,
      'tags': {'entrance': kind},
    };

BuildingAndEntranceFinder _finder(Object response, {int status = 200}) =>
    BuildingAndEntranceFinder(
        osmClient: OsmClient(
            client: MockClient(
                (_) async => http.Response(jsonEncode(response), status))));

const _insideBuilding = LatLng(50.0005, 6.0005);

void main() {
  group('BuildingAndEntranceFinder', () {
    test('prefers entrance=main over other entrances', () async {
      final finder = _finder(_buildingResponse([
        _entrance(20, 50.0, 6.0, 'yes'),
        _entrance(22, 50.001, 6.001, 'main'),
      ]));
      expect(await finder.findBuildingAndEntrance([_insideBuilding]),
          [const LatLng(50.001, 6.001)]);
    });

    test('ignores entrances of other buildings', () async {
      final finder = _finder(_buildingResponse([
        _entrance(99, 50.0003, 6.0011, 'main'), // not part of the outline
      ]));
      expect(await finder.findBuildingAndEntrance([_insideBuilding]),
          [_insideBuilding]);
    });

    test('keeps locations outside of buildings', () async {
      final finder =
          _finder(_buildingResponse([_entrance(20, 50.0, 6.0, 'main')]));
      const outside = LatLng(50.002, 6.002);
      expect(await finder.findBuildingAndEntrance([outside]), [outside]);
    });

    test('falls back to the input on API failure', () async {
      final finder = _finder({}, status: 500);
      expect(await finder.findBuildingAndEntrance([_insideBuilding]),
          [_insideBuilding]);
    });

    test('isPointInPolygon handles degenerate polygons', () {
      final finder = BuildingAndEntranceFinder();
      expect(
          finder.isPointInPolygon(_insideBuilding, {
            'geometry': [
              {'lat': 50.0, 'lon': 6.0}
            ]
          }),
          isFalse);
    });
  });

  group('TripService online flows (mocked)', () {
    test('replaces waypoints with entrances and includes them in the route',
        () async {
      final service = TripService(httpClient: MockClient((request) async {
        final query = request.bodyFields['data'] ?? '';
        if (query.contains('"entrance"')) {
          // The start waypoint lies in a building whose entrance is node 1.
          return http.Response(
              jsonEncode({
                'elements': [
                  {
                    'type': 'way',
                    'id': 500,
                    'nodes': [1, 30, 31, 32, 1],
                    'tags': {'building': 'yes'},
                    'geometry': [
                      {'lat': 50.0, 'lon': 6.0},
                      {'lat': 49.9995, 'lon': 6.0},
                      {'lat': 49.9995, 'lon': 5.9995},
                      {'lat': 50.0, 'lon': 5.9995},
                      {'lat': 50.0, 'lon': 6.0},
                    ],
                  },
                  _entrance(1, 50.0, 6.0, 'main'),
                ],
              }),
              200);
        }
        return http.Response(jsonEncode({'elements': fixture}), 200);
      }));

      const inBuilding = LatLng(49.9998, 5.9998);
      final trip = await service.findTotalTrip(
        [inBuilding, const LatLng(50.0, 6.004)],
        replaceWaypointsWithBuildingEntrances: true,
      );
      expect(trip.errors, isEmpty);
      expect(trip.route.first, const LatLng(50.0, 6.0));
      expect(trip.route, isNot(contains(inBuilding)));
    });

    // Routing currently runs synchronously after the last await, so this
    // guards against regressions if an await is added between fetching the
    // graph and routing on it.
    test('concurrent calls each route on their own graph', () async {
      // A far-away road that must not leak into the other request.
      final otherCity = [
        osmNode(900, 10.0, 10.0),
        osmNode(901, 10.0, 10.001),
        osmWay(902, [900, 901], 'residential'),
      ];
      final service = TripService(httpClient: MockClient((request) async {
        final query = request.bodyFields['data']!;
        if (query.contains('(49.')) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(jsonEncode({'elements': fixture}), 200);
        }
        return http.Response(jsonEncode({'elements': otherCity}), 200);
      }));

      final slow = service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
      final fast = service.findTotalTrip(
          [const LatLng(10.0, 10.0), const LatLng(10.0, 10.001)]);
      final results = await Future.wait([slow, fast]);

      expect(results[0].errors, isEmpty);
      expect(results[0].route.first, const LatLng(50.0, 6.0));
      expect(results[0].route.last, const LatLng(50.0, 6.004));
      expect(results[1].route.first, const LatLng(10.0, 10.0));
    });

    test('useOnlineData leaves offline mode', () async {
      final service = TripService(httpClient: overpassMock())
        ..graph = Graph()
        ..currentCity = 'Empty';
      final offline = await service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
      expect(offline.errors, ['Graph data unavailable']);

      service.useOnlineData();
      final online = await service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
      expect(service.currentCity, isNull);
      expect(online.errors, isEmpty);
      expect(online.route, isNotEmpty);
    });
  });

  group('routing edge cases', () {
    test('unreachable legs are reported per leg and skipped', () async {
      final graph = buildGraphFromOsmElements(fixture, minIslandSize: 0);
      final service = TripService()
        ..graph = graph
        ..currentCity = 'Fixture';
      final trip = await service
          .findTotalTrip([pos(graph, 1), pos(graph, 10), pos(graph, 11)]);
      expect(trip.errors, ['Leg 1: No path found.']);
      // The reachable second leg is still routed.
      expect(trip.route, [pos(graph, 10), pos(graph, 11)]);
    });

    test('Graph.removeNode removes edges pointing at the node', () {
      final graph = buildGraphFromOsmElements(fixture);
      graph.removeNode(2);
      expect(graph.nodes.containsKey(2), isFalse);
      expect(graph.adjacencyList[1]!.map((e) => e.to), isNot(contains(2)));
      expect(graph.adjacencyList[3]!.map((e) => e.to), isNot(contains(2)));
    });

    test('removeSmallIslands honours the size threshold', () {
      final keepAll = buildGraphFromOsmElements(fixture, minIslandSize: 1);
      expect(keepAll.nodes.keys, containsAll([10, 11]));
      final graph = buildGraphFromOsmElements(fixture, minIslandSize: 2);
      expect(graph.nodes.keys, isNot(contains(10)));
    });

    test('ignores malformed OSM elements', () {
      final graph = buildGraphFromOsmElements([
        ...fixture,
        'garbage',
        {'type': 'node', 'id': 'x', 'lat': 1, 'lon': 1},
        {'type': 'node', 'id': 77, 'lat': double.nan, 'lon': 1.0},
        {'type': 'way', 'id': 78, 'nodes': 'nope'},
        {
          'type': 'way',
          'id': 79,
          'nodes': [1, 999]
        },
      ]);
      expect(graph.nodes.keys, unorderedEquals([1, 2, 3, 4, 5, 6, 7]));
    });

    test('findLatLonBounds rejects empty input', () {
      expect(() => findLatLonBounds([]), throwsArgumentError);
    });
  });
}
