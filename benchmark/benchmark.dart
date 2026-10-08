// ignore_for_file: avoid_print
// Benchmarks for trip_routing.
//
//   dart run benchmark/benchmark.dart load <cacheFile>   # load time + memory
//   dart run benchmark/benchmark.dart route <cacheFile>  # snapping + routing
//   dart run benchmark/benchmark.dart online [runs]      # live Overpass
//
// Run `load` in a fresh process per file so memory numbers are not skewed.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

final _cases = {
  'short (900 m)': [
    const LatLng(50.77437, 6.07542),
    const LatLng(50.77472, 6.08398)
  ],
  'cross-city (21 km)': [const LatLng(50.70, 6.00), const LatLng(50.85, 6.15)],
  '10 waypoints': [
    for (var i = 0; i < 10; i++) LatLng(50.76 + i * 0.002, 6.07 + i * 0.002)
  ],
};

Future<void> main(List<String> args) async {
  switch (args.firstOrNull) {
    case 'load':
      await _load(args[1]);
    case 'route':
      await _route(args[1]);
    case 'online':
      await _online(int.tryParse(args.elementAtOrNull(1) ?? '') ?? 3);
    default:
      stderr.writeln('usage: benchmark.dart load|route <file> | online [runs]');
      exitCode = 64;
  }
}

Future<void> _load(String file) async {
  final rssBefore = ProcessInfo.currentRss;
  final sw = Stopwatch()..start();
  final graph = await Graph.fromFile(file);
  final ms = sw.elapsedMilliseconds;
  final edges = graph.adjacencyList.values.fold(0, (s, e) => s + e.length);
  print('load $file: ${(File(file).lengthSync() / 1e6).toStringAsFixed(1)} MB, '
      '$ms ms, ${graph.nodes.length} nodes, $edges directed edges, '
      'peak +${(ProcessInfo.maxRss - rssBefore) ~/ 1000000} MB, '
      'retained +${(ProcessInfo.currentRss - rssBefore) ~/ 1000000} MB');
}

Future<void> _route(String file) async {
  final graph = await Graph.fromFile(file);
  final service = TripService()
    ..graph = graph
    ..currentCity = 'bench';
  const runs = 10;

  final points = _cases.values.expand((w) => w).toList();
  snapToGraph(graph, points.first); // warm-up (and index build, if any)
  final sw = Stopwatch()..start();
  for (var i = 0; i < runs; i++) {
    for (final p in points) {
      snapToGraph(graph, p);
    }
  }
  print(
      'snap: ${(sw.elapsedMicroseconds / runs / points.length / 1000).toStringAsFixed(3)} ms/waypoint');

  for (final MapEntry(key: name, value: waypoints) in _cases.entries) {
    await service.findTotalTrip(waypoints); // warm-up
    sw.reset();
    late Trip trip;
    for (var i = 0; i < runs; i++) {
      trip = await service.findTotalTrip(waypoints);
    }
    print(
        '$name: ${(sw.elapsedMicroseconds / runs / 1000).toStringAsFixed(1)} ms, '
        '${trip.distance.toStringAsFixed(1)} m, ${trip.route.length} points, '
        'errors ${trip.errors}');
  }
}

Future<void> _online(int runs) async {
  final waypoints = _cases['short (900 m)']!;
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final service = TripService(httpClient: _TimingClient());
    final sw = Stopwatch()..start();
    final trip = await service.findTotalTrip(waypoints,
        replaceWaypointsWithBuildingEntrances: true);
    times.add(sw.elapsedMilliseconds);
    print('online cold #$i: ${sw.elapsedMilliseconds} ms, '
        '${trip.distance.round()} m, errors ${trip.errors}');
    sw.reset();
    final repeat = await service.findTotalTrip(waypoints,
        replaceWaypointsWithBuildingEntrances: true);
    print('online repeat #$i: ${sw.elapsedMilliseconds} ms, '
        '${repeat.distance.round()} m, errors ${repeat.errors}');
  }
  times.sort();
  print('online cold median: ${times[times.length ~/ 2]} ms');

  // Once roads and entrances are cached, repeats need no network at all.
  final service = TripService(httpClient: _TimingClient());
  for (var i = 0; i < 6; i++) {
    final sw = Stopwatch()..start();
    final trip = await service.findTotalTrip(waypoints,
        replaceWaypointsWithBuildingEntrances: true);
    print('same service call #$i: ${sw.elapsedMilliseconds} ms, '
        '${trip.distance.round()} m, errors ${trip.errors}');
  }
}

/// Logs each request's duration, to show which requests overlap.
class _TimingClient extends http.BaseClient {
  final _inner = http.Client();
  final _start = DateTime.now();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final kind = request.url.host.contains('nominatim')
        ? 'nominatim'
        : (request is http.Request && request.body.contains('entrance'))
            ? 'entrances'
            : 'roads';
    final begin = DateTime.now().difference(_start).inMilliseconds;
    final response = await _inner.send(request);
    final body = await response.stream.toBytes();
    final end = DateTime.now().difference(_start).inMilliseconds;
    print('  $kind: $begin-$end ms (${end - begin} ms, '
        'HTTP ${response.statusCode}, ${body.length ~/ 1000} kB)');
    return http.StreamedResponse(Stream.value(body), response.statusCode,
        headers: response.headers, request: request);
  }
}
