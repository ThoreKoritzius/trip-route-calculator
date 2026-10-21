import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

/// Study harness, not a production graph distribution implementation.
class NoNetworkClient extends http.BaseClient {
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    throw StateError('Network disabled for offline study');
  }
}

class LocalCity extends TripService {
  LocalCity(this.path, NoNetworkClient client) : super(httpClient: client);
  final String path;
  @override
  Future<String> getCityPath(String cityName) async => path;
}

int edges(Graph graph) =>
    graph.adjacencyList.values.fold(0, (n, list) => n + list.length);

List<List<int>> components(Graph graph) {
  final visited = <int>{};
  final result = <List<int>>[];
  for (final id in graph.nodes.keys) {
    if (visited.contains(id)) continue;
    final component = <int>[];
    final stack = <int>[id];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (!visited.add(current)) continue;
      component.add(current);
      stack.addAll((graph.adjacencyList[current] ?? [])
          .map((e) => e.to)
          .where((n) => !visited.contains(n)));
    }
    result.add(component);
  }
  result.sort((a, b) => b.length.compareTo(a.length));
  return result;
}

double percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * p).round()];
}

Future<void> main(List<String> args) async {
  if (args.length != 3 || !{'build', 'route'}.contains(args.first)) {
    stderr.writeln(
        'Usage: probe build elements.json husum.trg | probe route husum.trg metrics.json');
    exit(64);
  }
  final watch = Stopwatch()..start();
  final rssBefore = ProcessInfo.currentRss;
  if (args.first == 'build') {
    final data = jsonDecode(await File(args[1]).readAsString()) as Map;
    final decodedMs = watch.elapsedMicroseconds / 1000;
    final graph = buildGraphFromOsmElements(data['elements'] as List);
    graph.createdAt = DateTime.now().toUtc();
    final builtMs = watch.elapsedMicroseconds / 1000;
    await graph.saveGraph(args[2]);
    final metrics = {
      'json_decode_ms': decodedMs,
      'graph_build_ms': builtMs - decodedMs,
      'total_build_and_write_ms': watch.elapsedMicroseconds / 1000,
      'nodes': graph.nodes.length,
      'directed_edges': edges(graph),
      'graph_bytes': await File(args[2]).length(),
      'rss_before_bytes': rssBefore,
      'rss_after_bytes': ProcessInfo.currentRss,
      'process_peak_rss_bytes': ProcessInfo.maxRss,
    };
    await File('${args[2]}.build.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(metrics)}\n');
    stdout.writeln(jsonEncode(metrics));
    return;
  }
  final network = NoNetworkClient();
  final service = LocalCity(args[1], network);
  if (!await service.useCity('Husum')) throw StateError('Graph load failed');
  final loadMs = watch.elapsedMicroseconds / 1000;
  final loadedRss = ProcessInfo.currentRss;
  final graph = service.graph;
  final connected = components(graph);
  final tours = <String, List<LatLng>>{
    'market_harbour_castle_loop': const [
      LatLng(54.4775, 9.0519),
      LatLng(54.4758, 9.0499),
      LatLng(54.4802, 9.0501),
      LatLng(54.4775, 9.0519),
    ],
    'station_market': const [LatLng(54.4724, 9.0566), LatLng(54.4775, 9.0519)],
  };
  final tourResults = <Map<String, Object?>>[];
  var failures = 0;
  for (final entry in tours.entries) {
    watch.reset();
    final trip = await service.findTotalTrip(entry.value,
        replaceWaypointsWithBuildingEntrances: true);
    final elapsed = watch.elapsedMicroseconds / 1000;
    final good =
        trip.errors.isEmpty && trip.route.length > 2 && trip.distance > 0;
    if (!good) failures++;
    tourResults.add({
      'name': entry.key,
      'route_ms': elapsed,
      'distance_m': trip.distance,
      'route_points': trip.route.length,
      'errors': trip.errors,
      'start_snap_m': trip.route.isEmpty
          ? null
          : haversineDistance(
              trip.route.first.latitude,
              trip.route.first.longitude,
              entry.value.first.latitude,
              entry.value.first.longitude),
      'end_snap_m': trip.route.isEmpty
          ? null
          : haversineDistance(
              trip.route.last.latitude,
              trip.route.last.longitude,
              entry.value.last.latitude,
              entry.value.last.longitude),
    });
  }
  // Deterministic pairs sampled from the largest connected component only.
  // This measures route computation, not arbitrary-point accessibility/coverage.
  final nodes = connected.first.map((id) => graph.nodes[id]!).toList();
  final random = Random(20261021);
  final times = <double>[];
  final distances = <double>[];
  for (var i = 0; i < 200; i++) {
    final a = nodes[random.nextInt(nodes.length)];
    final b = nodes[random.nextInt(nodes.length)];
    if (a.id == b.id) {
      i--;
      continue;
    }
    watch.reset();
    final trip = await service
        .findTotalTrip([LatLng(a.lat, a.lon), LatLng(b.lat, b.lon)]);
    times.add(watch.elapsedMicroseconds / 1000);
    distances.add(trip.distance);
    if (trip.errors.isNotEmpty || trip.route.length < 2 || trip.distance <= 0) {
      failures++;
    }
  }
  // A clearly out-of-area waypoint must fail; never report its partial path as complete.
  final outside = await service
      .findTotalTrip(const [LatLng(54.4775, 9.0519), LatLng(55, 10)]);
  final bytes = await File(args[1]).readAsBytes();
  final truncated = bytes.sublist(0, bytes.length ~/ 2);
  var rejectedTruncated = false;
  try {
    Graph.fromBytes(truncated);
  } on FormatException {
    rejectedTruncated = true;
  }
  final metrics = {
    'load_ms': loadMs,
    'nodes': graph.nodes.length,
    'directed_edges': edges(graph),
    'component_sizes': connected.map((c) => c.length).toList(),
    'rss_before_bytes': rssBefore,
    'rss_after_load_bytes': loadedRss,
    'rss_after_routes_bytes': ProcessInfo.currentRss,
    'process_peak_rss_bytes': ProcessInfo.maxRss,
    'tours': tourResults,
    'random_route_count': times.length,
    'random_route_median_ms': percentile(times, .5),
    'random_route_p95_ms': percentile(times, .95),
    'random_route_max_ms': times.reduce(max),
    'random_distance_median_m': percentile(distances, .5),
    'route_failures': failures,
    'http_requests': network.requests,
    'outside_area_errors': outside.errors,
    'truncated_graph_rejected': rejectedTruncated,
  };
  await File(args[2]).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(metrics)}\n');
  stdout.writeln(jsonEncode(metrics));
  if (failures != 0 ||
      network.requests != 0 ||
      outside.errors.isEmpty ||
      !rejectedTruncated) {
    exitCode = 1;
  }
  network.close();
}
