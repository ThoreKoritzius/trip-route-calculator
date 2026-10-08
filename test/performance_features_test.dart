import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';

import 'fixtures.dart';

/// A random street-like grid: jittered nodes, ~15% of links missing, some
/// footways and stairs.
Graph _randomGraph(int seed, {int size = 30}) {
  final random = Random(seed);
  final elements = <Map<String, dynamic>>[];
  int id(int x, int y) => x * size + y + 1;
  for (var x = 0; x < size; x++) {
    for (var y = 0; y < size; y++) {
      elements.add(osmNode(
          id(x, y),
          50.0 + y * 0.001 + random.nextDouble() * 0.0006,
          6.0 + x * 0.0015 + random.nextDouble() * 0.0006));
    }
  }
  var wayId = 1;
  const kinds = ['residential', 'residential', 'footway', 'steps'];
  for (var x = 0; x < size; x++) {
    for (var y = 0; y < size; y++) {
      for (final (dx, dy) in [(1, 0), (0, 1)]) {
        if (x + dx >= size || y + dy >= size || random.nextDouble() < 0.15) {
          continue;
        }
        elements.add(osmWay(wayId++, [id(x, y), id(x + dx, y + dy)],
            kinds[random.nextInt(kinds.length)]));
      }
    }
  }
  return buildGraphFromOsmElements(elements, minIslandSize: 0);
}

/// Reference Dijkstra over plain edge weights.
double? _dijkstra(Graph graph, int start, int target) {
  final dist = <int, double>{start: 0};
  final queue = PriorityQueue<(int, double)>((a, b) => a.$2.compareTo(b.$2))
    ..add((start, 0));
  final done = <int>{};
  while (queue.isNotEmpty) {
    final (node, d) = queue.removeFirst();
    if (!done.add(node)) continue;
    if (node == target) return d;
    for (final edge in graph.adjacencyList[node]!) {
      final nd = d + edge.weight;
      if (nd < (dist[edge.to] ?? double.infinity)) {
        dist[edge.to] = nd;
        queue.add((edge.to, nd));
      }
    }
  }
  return null;
}

void main() {
  group('binary graph format', () {
    test('round-trips nodes, edges, flags and timestamp', () {
      final graph = _randomGraph(1)..createdAt = DateTime.utc(2026, 5, 6, 7);
      final decoded = Graph.fromBytes(graph.toBytes());

      expect(decoded.createdAt, graph.createdAt);
      expect(decoded.nodes.length, graph.nodes.length);
      for (final node in graph.nodes.values) {
        final other = decoded.nodes[node.id]!;
        expect((other.lat, other.lon, other.isFootWay),
            (node.lat, node.lon, node.isFootWay));
        final edges = graph.adjacencyList[node.id]!;
        final otherEdges = decoded.adjacencyList[node.id]!;
        expect(otherEdges.map((e) => (e.to, e.isFootWay, e.isSteps)),
            edges.map((e) => (e.to, e.isFootWay, e.isSteps)));
        for (var i = 0; i < edges.length; i++) {
          expect(otherEdges[i].weight, closeTo(edges[i].weight, 1e-4));
        }
      }
    });

    test('keeps 64-bit OSM node ids exact', () {
      final graph = buildGraphFromOsmElements([
        osmNode(12345678901, 50.0, 6.0),
        osmNode(12345678902, 50.0, 6.001),
        osmWay(1, [12345678901, 12345678902], 'footway'),
      ]);
      expect(Graph.fromBytes(graph.toBytes()).nodes.keys,
          [12345678901, 12345678902]);
    });

    test('is much smaller than JSON', () {
      final graph = _randomGraph(2);
      final json = utf8.encode(jsonEncode(graph.toJson()));
      expect(graph.toBytes().length, lessThan(json.length / 3));
    });

    test('decodes from unaligned buffers', () {
      final bytes = _randomGraph(3).toBytes();
      final padded = Uint8List(bytes.length + 3)
        ..setRange(3, 3 + bytes.length, bytes);
      final view = Uint8List.sublistView(padded, 3);
      expect(Graph.fromBytes(view).nodes, isNotEmpty);
    });

    test('rejects truncated files', () {
      final bytes = _randomGraph(4).toBytes();
      expect(() => Graph.fromBytes(Uint8List.sublistView(bytes, 0, 100)),
          throwsFormatException);
    });

    test('still reads legacy JSON', () {
      final graph = _randomGraph(5);
      final legacy = utf8.encode(jsonEncode(graph.toJson()));
      expect(Graph.fromBytes(Uint8List.fromList(legacy)).nodes.length,
          graph.nodes.length);
    });
  });

  group('city cache files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('trip_routing'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('migrates a legacy <city>.json cache to the binary format', () async {
      await buildGraphFromOsmElements(fixture)
          .saveGraph('${dir.path}/Fixture.json', asJson: true);
      final service = _CityService(dir);
      expect(await service.useCity('Fixture'), isTrue);
      final migrated = File('${dir.path}/Fixture.trg');
      expect(migrated.existsSync(), isTrue);
      expect(migrated.readAsBytesSync().sublist(0, 4), utf8.encode('TRG1'));
      expect(service.graph.nodes.length, 7);
    });
  });

  group('spatial index', () {
    test('matches a brute-force search', () {
      final graph = _randomGraph(6);
      final allEdges = graph.adjacencyList.values.expand((e) => e).toList();
      final random = Random(7);
      for (var i = 0; i < 300; i++) {
        // Points inside and well outside the network.
        final p = LatLng(49.99 + random.nextDouble() * 0.05,
            5.99 + random.nextDouble() * 0.07);
        final indexed = snapToGraph(graph, p)!;
        final brute = snapToEdges(graph, p, allEdges, () => const [])!;
        expect(indexed.distance, closeTo(brute.distance, 1e-9),
            reason: 'at $p');
      }
    });

    test('is rebuilt after the graph changes', () {
      final graph = buildGraphFromOsmElements(fixture);
      const far = LatLng(50.0, 6.02);
      expect(snapToGraph(graph, far)!.distance, greaterThan(1000));
      graph
        ..addNode(Node(100, 50.0, 6.0199, false))
        ..addNode(Node(101, 50.0, 6.0201, false))
        ..addEdge(Edge(100, 101, 14.3));
      expect(snapToGraph(graph, far)!.distance, lessThan(1));
    });
  });

  group('A* search', () {
    test('finds the same shortest distances as Dijkstra', () {
      final service = TripService();
      for (var seed = 10; seed < 13; seed++) {
        final graph = _randomGraph(seed);
        final ids = graph.nodes.keys.toList();
        final random = Random(seed);
        for (var i = 0; i < 40; i++) {
          final a = ids[random.nextInt(ids.length)];
          final b = ids[random.nextInt(ids.length)];
          final expected = _dijkstra(graph, a, b);
          final trip =
              service.shortestPath(graph, a, b, preferWalkingPaths: false);
          if (expected == null) {
            expect(trip.errors, isNotEmpty);
          } else {
            expect(trip.distance, closeTo(expected, 1e-6),
                reason: 'seed $seed, $a -> $b');
          }
        }
      }
    });

    test('stays optimal with walking preference and avoided stairs', () {
      // Weighted costs via a Dijkstra on scaled weights.
      final graph = _randomGraph(20);
      const costs = RouteCosts(footwayCostFactor: 0.7, avoidSteps: true);
      final scaled = Graph();
      graph.nodes.values.forEach(scaled.addNode);
      for (final edges in graph.adjacencyList.values) {
        for (final e in edges) {
          scaled.adjacencyList[e.from]!
              .add(Edge(e.from, e.to, e.weight * costs.factor(e)));
        }
      }
      final ids = graph.nodes.keys.toList();
      final random = Random(21);
      for (var i = 0; i < 40; i++) {
        final a = graph.nodes[ids[random.nextInt(ids.length)]]!;
        final b = graph.nodes[ids[random.nextInt(ids.length)]]!;
        final expectedCost = _dijkstra(scaled, a.id, b.id);
        final route = routeBetween(
            graph, GraphSnap.atNode(a), GraphSnap.atNode(b), costs);
        if (expectedCost == null) {
          expect(route, isNull);
          continue;
        }
        // Recompute the cost of the returned route from its edges.
        final byPoint = {
          for (final n in graph.nodes.values) LatLng(n.lat, n.lon): n.id
        };
        final nodeIds = route!.route.map((p) => byPoint[p]!).toList();
        var cost = 0.0;
        for (var j = 0; j < nodeIds.length - 1; j++) {
          final edge = graph.adjacencyList[nodeIds[j]]!
              .where((e) => e.to == nodeIds[j + 1])
              .map((e) => e.weight * costs.factor(e))
              .reduce(min);
          cost += edge;
        }
        expect(cost, closeTo(expectedCost, 1e-6));
      }
    });
  });

  group('entrance lookup cache', () {
    test('serves repeated lookups from memory, retries failures', () async {
      final queries = <String>[];
      var fail = true;
      final finder = BuildingAndEntranceFinder(
          osmClient: OsmClient(client: MockClient((r) async {
        queries.add(r.bodyFields['data']!);
        return fail
            ? http.Response('busy', 504)
            : http.Response('{"elements": []}', 200);
      })));
      const a = LatLng(50.0, 6.0), b = LatLng(50.1, 6.1);

      expect(await finder.findBuildingAndEntrance([a]), [a]);
      fail = false;
      expect(await finder.findBuildingAndEntrance([a]), [a]);
      expect(queries, hasLength(2)); // the failure was not cached

      expect(await finder.findBuildingAndEntrance([a, b, a]), [a, b, a]);
      expect(queries, hasLength(3));
      expect(queries.last, isNot(contains('50.0, 6.0'))); // only b queried
      expect(queries.last, contains('50.1, 6.1'));

      await finder.findBuildingAndEntrance([b, a]);
      expect(queries, hasLength(3));
    });
  });

  group('online requests', () {
    test('entrances and roads are fetched in parallel', () async {
      var inFlight = 0, maxInFlight = 0;
      final service = TripService(
          osmClient: OsmClient(
              retryDelay: Duration.zero,
              client: MockClient((request) async {
                maxInFlight = max(maxInFlight, ++inFlight);
                await Future<void>.delayed(const Duration(milliseconds: 20));
                inFlight--;
                return request.bodyFields['data']!.contains('"entrance"')
                    ? http.Response('{"elements": []}', 200)
                    : fixtureHandler(request);
              })));
      final trip = await service.findTotalTrip(
          [const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)],
          replaceWaypointsWithBuildingEntrances: true);
      expect(trip.errors, isEmpty);
      expect(maxInFlight, 2);
    });

    test('reuses the fetched area for requests inside it', () async {
      var requests = 0;
      final service = TripService(osmClient: OsmClient(client: MockClient((r) {
        requests++;
        return fixtureHandler(r);
      })));
      final first = await service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)]);
      // Inside the first area (which has >= 500 m padding).
      final second = await service.findTotalTrip(
          [const LatLng(50.0, 6.001), const LatLng(50.0, 6.003)]);
      expect(requests, 1);
      expect(second.errors, isEmpty);
      expect(second.boundingBox, first.boundingBox);

      // Outside of it: fetched again.
      await service
          .findTotalTrip([const LatLng(50.0, 6.0), const LatLng(50.05, 6.004)]);
      expect(requests, 2);
    });

    test('area reuse can be disabled and expires', () async {
      var requests = 0;
      Future<http.Response> handler(http.Request r) {
        requests++;
        return fixtureHandler(r);
      }

      final waypoints = [const LatLng(50.0, 6.0), const LatLng(50.0, 6.004)];
      final disabled = TripService(
          osmClient: OsmClient(client: MockClient(handler)),
          onlineCacheDuration: Duration.zero);
      await disabled.findTotalTrip(waypoints);
      await disabled.findTotalTrip(waypoints);
      expect(requests, 2);

      final expiring = TripService(
          osmClient: OsmClient(client: MockClient(handler)),
          onlineCacheDuration: const Duration(milliseconds: 1));
      await expiring.findTotalTrip(waypoints);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await expiring.findTotalTrip(waypoints);
      expect(requests, 4);
    });
  });
}

class _CityService extends TripService {
  final Directory dir;
  _CityService(this.dir)
      : super(
            osmClient: OsmClient(
                client: MockClient((_) => throw StateError('network used'))));

  @override
  Future<String> getCityPath(String cityName) async =>
      '${dir.path}/$cityName.trg';
}
