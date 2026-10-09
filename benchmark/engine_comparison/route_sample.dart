// ignore_for_file: avoid_print
// Samples random walking trips on a city graph and routes them with
// trip_routing (see README.md in this directory).
//
//   dart run benchmark/engine_comparison/route_sample.dart <graph.trg> <out.json> <trips>
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

Future<void> main(List<String> a) async {
  final graph = await Graph.fromFile(a[0]);
  final service = TripService()
    ..graph = graph
    ..currentCity = 'Aachen';
  final inner = graph.nodes.values
      .where((n) =>
          n.lat > 50.73 &&
          n.lat < 50.83 &&
          n.lon > 6.02 &&
          n.lon < 6.15 &&
          graph.adjacencyList[n.id]!.isNotEmpty)
      .toList();
  final random = Random(2026);
  final buckets = [(300.0, 1000.0), (1000.0, 2000.0), (2000.0, 5000.0)];
  final trips = <Map<String, dynamic>>[];
  for (final (lo, hi) in buckets) {
    var made = 0;
    while (made <
        int.parse(a[2]) ~/ 3 +
            (buckets.first.$1 == lo ? int.parse(a[2]) % 3 : 0)) {
      final s = inner[random.nextInt(inner.length)],
          e = inner[random.nextInt(inner.length)];
      final d = haversineDistance(s.lat, s.lon, e.lat, e.lon);
      if (d < lo || d >= hi) continue;
      final wps = [LatLng(s.lat, s.lon), LatLng(e.lat, e.lon)];
      final result = <String, dynamic>{
        'start': [s.lat, s.lon],
        'end': [e.lat, e.lon],
        'crow': d
      };
      for (final (key, prefer) in [('ours', true), ('ours_shortest', false)]) {
        await service.findTotalTrip(wps, preferWalkingPaths: prefer); // warm
        final times = <double>[];
        late Trip trip;
        for (var i = 0; i < 5; i++) {
          final sw = Stopwatch()..start();
          trip = await service.findTotalTrip(wps, preferWalkingPaths: prefer);
          times.add(sw.elapsedMicroseconds / 1000);
        }
        times.sort();
        result[key] = {
          'distance': trip.distance,
          'ms': times[2],
          'errors': trip.errors,
          'coords': [
            for (final p in trip.route) [p.latitude, p.longitude]
          ]
        };
      }
      trips.add(result);
      made++;
    }
  }
  File(a[1]).writeAsStringSync(jsonEncode(trips));
  final errs =
      trips.where((t) => (t['ours']['errors'] as List).isNotEmpty).length;
  final ms = trips.map((t) => t['ours']['ms'] as double).toList()..sort();
  print(
      '${trips.length} trips, $errs with errors; ours median ${ms[ms.length ~/ 2].toStringAsFixed(2)} ms, p95 ${ms[(ms.length * 0.95).floor()].toStringAsFixed(2)} ms');
}
