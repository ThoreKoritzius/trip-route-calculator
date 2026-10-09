// ignore_for_file: avoid_print
// Builds a trip_routing city graph from Overpass-style JSON elements.
//
//   dart run benchmark/engine_comparison/build_graph.dart <elements.json> <out.trg>
import 'dart:convert';
import 'dart:io';

import 'package:trip_routing/trip_routing.dart';

Future<void> main(List<String> args) async {
  final sw = Stopwatch()..start();
  final json = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final graph = buildGraphFromOsmElements(json['elements'] as List)
    ..createdAt = DateTime.now().toUtc();
  await graph.saveGraph(args[1]);
  print('${graph.nodes.length} nodes, built and saved in '
      '${sw.elapsedMilliseconds} ms');
}
