import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';

Map<String, dynamic> _node(int id, double lat, double lon) =>
    {'type': 'node', 'id': id, 'lat': lat, 'lon': lon};

Map<String, dynamic> _way(int id, List<int> nodes, String highway) => {
      'type': 'way',
      'id': id,
      'nodes': nodes,
      'tags': {'highway': highway},
    };

/// 1 --road-- 2 --road-- 3 -- 5 ~(5 cm)~ 6 -- 7
///  \______footway 4______/
/// plus a disconnected island 10 -- 11.
final _fixture = <Map<String, dynamic>>[
  _node(1, 50.0, 6.000),
  _node(2, 50.0, 6.001),
  _node(3, 50.0, 6.002),
  _node(4, 50.0002, 6.001),
  _node(5, 50.0, 6.003),
  _node(6, 50.0000005, 6.003),
  _node(7, 50.0, 6.004),
  _node(10, 50.01, 6.01),
  _node(11, 50.01, 6.011),
  _way(100, [1, 2, 3], 'primary'),
  _way(101, [1, 4, 3], 'footway'),
  _way(102, [3, 5, 6, 7], 'residential'),
  _way(103, [10, 11], 'residential'),
];

LatLng _pos(Graph g, int id) => LatLng(g.nodes[id]!.lat, g.nodes[id]!.lon);

int _edgeCount(Graph g) =>
    g.adjacencyList.values.fold(0, (sum, edges) => sum + edges.length);

http.Client _overpassMock({List<String>? userAgents}) => MockClient((request) {
      userAgents?.add(request.headers['User-Agent'] ?? '');
      if (request.url.host == 'overpass-api.de') {
        return Future.value(
            http.Response(jsonEncode({'elements': _fixture}), 200));
      }
      if (request.url.host == 'nominatim.openstreetmap.org') {
        return Future.value(http.Response(
            jsonEncode([
              {
                'boundingbox': ['49.99', '50.02', '5.99', '6.02']
              }
            ]),
            200));
      }
      return Future.value(http.Response('not found', 404));
    });

class _TempCityService extends TripService {
  final Directory dir;
  _TempCityService(this.dir, http.Client client) : super(httpClient: client);

  @override
  Future<String> getCityPath(String cityName) async =>
      '${dir.path}/$cityName.json';
}

void main() {
  group('utils', () {
    test('haversineDistance matches a known distance', () {
      // 0.001 degrees of latitude is ~111.2 m
      expect(haversineDistance(50, 6, 50.001, 6), closeTo(111.2, 0.5));
    });

    test('findLatLonBounds applies minimum padding and clamps', () {
      final b = findLatLonBounds([const LatLng(50, 6), const LatLng(50, 6)],
          minPaddingDegrees: 0.01);
      expect(b, [49.99, 5.99, 50.01, 6.01]);

      final clamped = findLatLonBounds([const LatLng(89.999, 179.999)],
          minPaddingDegrees: 0.01);
      expect(clamped[2], 90.0);
      expect(clamped[3], 180.0);
    });
  });

  group('buildGraphFromOsmElements', () {
    final graph = buildGraphFromOsmElements(_fixture);

    test('removes small islands but keeps the largest component', () {
      expect(graph.nodes.keys, unorderedEquals([1, 2, 3, 4, 5, 6, 7]));
    });

    test('keeps very short segments connected', () {
      expect(graph.adjacencyList[5]!.map((e) => e.to), contains(6));
      expect(graph.adjacencyList[6]!.map((e) => e.to), containsAll([5, 7]));
    });

    test('flags highway=footway edges as walking ways', () {
      final edge14 = graph.adjacencyList[1]!.firstWhere((e) => e.to == 4);
      final edge12 = graph.adjacencyList[1]!.firstWhere((e) => e.to == 2);
      expect(edge14.isFootWay, isTrue);
      expect(edge12.isFootWay, isFalse);
    });
  });

  group('shortestPath', () {
    final graph = buildGraphFromOsmElements(_fixture);
    final service = TripService();

    test('prefers the slightly longer footway when asked to', () {
      final walking = service.shortestPath(graph, 1, 3);
      expect(walking.route, [_pos(graph, 1), _pos(graph, 4), _pos(graph, 3)]);

      final direct =
          service.shortestPath(graph, 1, 3, preferWalkingPaths: false);
      expect(direct.route, [_pos(graph, 1), _pos(graph, 2), _pos(graph, 3)]);
      expect(direct.distance, lessThan(walking.distance));
      expect(direct.distance, closeTo(143, 1));
    });

    test('identical start and target is a valid empty leg', () {
      final trip = service.shortestPath(graph, 2, 2);
      expect(trip.errors, isEmpty);
      expect(trip.distance, 0);
    });

    test('reports unreachable targets', () {
      final g = buildGraphFromOsmElements(_fixture, minIslandSize: 0);
      final trip = service.shortestPath(g, 1, 10);
      expect(trip.route, isEmpty);
      expect(trip.errors, isNotEmpty);
    });
  });

  group('Graph persistence', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('trip_routing'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('save/load round-trips without duplicating edges', () async {
      final graph = buildGraphFromOsmElements(_fixture);
      final path = '${dir.path}/g.json';
      await graph.saveGraph(path);
      final loaded = await Graph.fromFile(path);

      expect(loaded.nodes.length, graph.nodes.length);
      expect(_edgeCount(loaded), _edgeCount(graph));
      expect(loaded.adjacencyList[1]!.firstWhere((e) => e.to == 4).isFootWay,
          isTrue);
    });

    test('loads legacy files with integer coordinates and no edge flags',
        () async {
      final path = '${dir.path}/legacy.json';
      File(path).writeAsStringSync(jsonEncode({
        'nodes': [
          {'id': 1, 'lat': 50, 'lon': 6, 'isFootWay': false},
          {'id': 2, 'lat': 50.001, 'lon': 6, 'isFootWay': false},
        ],
        'edges': [
          {'from': 1, 'to': 2, 'weight': 111},
          {'from': 2, 'to': 1, 'weight': 111},
        ],
      }));
      final loaded = await Graph.fromFile(path);
      expect(_edgeCount(loaded), 2);
      expect(loaded.nodes[1]!.lat, 50.0);
    });
  });

  group('TripService.findTotalTrip (offline graph)', () {
    late TripService service;
    late Graph graph;

    setUp(() {
      graph = buildGraphFromOsmElements(_fixture);
      service = TripService()
        ..graph = graph
        ..currentCity = 'Fixture';
    });

    test('joins legs without repeating the shared node', () async {
      final trip = await service.findTotalTrip(
          [_pos(graph, 1), _pos(graph, 3), _pos(graph, 7)],
          preferWalkingPaths: false);
      expect(trip.errors, isEmpty);
      expect(trip.route, [
        for (final id in [1, 2, 3, 5, 6, 7]) _pos(graph, id)
      ]);
      expect(trip.distance, closeTo(286, 2));
    });

    test('consecutive waypoints on the same node are not an error', () async {
      final trip = await service
          .findTotalTrip([_pos(graph, 1), _pos(graph, 1), _pos(graph, 3)]);
      expect(trip.errors, isEmpty);
      expect(trip.route.first, _pos(graph, 1));
      expect(trip.route.last, _pos(graph, 3));
    });

    test('duplication penalty avoids re-using edges in either direction',
        () async {
      final waypoints = [_pos(graph, 1), _pos(graph, 3), _pos(graph, 1)];
      final noPenalty =
          await service.findTotalTrip(waypoints, preferWalkingPaths: false);
      expect(noPenalty.route.where((p) => p == _pos(graph, 2)).length, 2);

      final penalty = await service.findTotalTrip(waypoints,
          preferWalkingPaths: false, duplicationPenalty: 1000);
      expect(penalty.route.where((p) => p == _pos(graph, 2)).length, 1);
      expect(penalty.route.where((p) => p == _pos(graph, 4)).length, 1);
    });

    test('forceIncludeWaypoints adds the first and later waypoints', () async {
      const start = LatLng(49.9999, 6.0);
      const end = LatLng(49.9999, 6.004);
      final trip = await service
          .findTotalTrip([start, end], forceIncludeWaypoints: true);
      expect(trip.route.first, start);
      expect(trip.route.last, end);
    });

    test('rejects fewer than two waypoints', () async {
      final trip = await service.findTotalTrip([const LatLng(50, 6)]);
      expect(trip.errors, isNotEmpty);
    });
  });

  group('TripService online (mocked HTTP)', () {
    test('fetches the graph and routes between waypoints', () async {
      final userAgents = <String>[];
      final service =
          TripService(httpClient: _overpassMock(userAgents: userAgents));
      final trip = await service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
      expect(trip.errors, isEmpty);
      expect(trip.distance, greaterThan(250));
      expect(trip.boundingBox, isNotNull);
      expect(userAgents.single, startsWith('trip_routing'));
    });

    test('surfaces HTTP failures as errors', () async {
      final service = TripService(
          httpClient: MockClient((_) async => http.Response('busy', 429)));
      final trip = await service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
      expect(trip.route, isEmpty);
      expect(trip.errors.single, contains('429'));
    });

    test('useCity downloads once and then loads from the cache', () async {
      final dir = Directory.systemTemp.createTempSync('trip_routing');
      addTearDown(() => dir.deleteSync(recursive: true));

      final first = _TempCityService(dir, _overpassMock());
      expect(await first.useCity('Fixture'), isTrue);
      expect(File('${dir.path}/Fixture.json').existsSync(), isTrue);

      final offline = _TempCityService(
          dir, MockClient((_) => throw StateError('network used')));
      expect(await offline.useCity('Fixture'), isTrue);
      expect(offline.currentCity, 'Fixture');
      expect(offline.graph.nodes.length, 7);
    });

    test('useCity fails cleanly when the city cannot be fetched', () async {
      final dir = Directory.systemTemp.createTempSync('trip_routing');
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = _TempCityService(
          dir, MockClient((_) async => http.Response('[]', 200)));
      expect(await service.useCity('Nowhere'), isFalse);
      expect(service.currentCity, isNull);
      expect(File('${dir.path}/Nowhere.json').existsSync(), isFalse);
    });
  });

  group('BuildingAndEntranceFinder', () {
    test('finds the entrance on the building outline', () async {
      final response = {
        'elements': [
          {
            'type': 'way',
            'id': 1,
            'nodes': [10, 11, 12, 13, 10],
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
          {
            'type': 'node',
            'id': 11,
            'lat': 50.0,
            'lon': 6.001,
            'tags': {'entrance': 'main'},
          },
        ],
      };
      final finder = BuildingAndEntranceFinder(
          osmClient: OsmClient(
              client: MockClient(
                  (_) async => http.Response(jsonEncode(response), 200))));
      final result = await finder.findBuildingAndEntrance(
          [const LatLng(50.0005, 6.0005), const LatLng(51, 7)]);
      expect(result, [const LatLng(50.0, 6.001), const LatLng(51, 7)]);
    });
  });
}
