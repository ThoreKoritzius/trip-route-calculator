import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../models/edge.dart';
import '../models/graph.dart';

/// Uniform grid over the graph's segments for fast nearest-segment queries.
class SegmentIndex {
  /// Cell size in degrees (~110 m of latitude).
  static const double cellDegrees = 0.001;
  static const double _metersPerDegree = 6371e3 * pi / 180;

  final int revision;
  final Map<int, List<Edge>> _cells = {};
  int _minX = 1 << 30, _maxX = -(1 << 30), _minY = 1 << 30, _maxY = -(1 << 30);

  static final _cache = Expando<SegmentIndex>('SegmentIndex');

  /// The index for [graph], (re)built if the graph changed since.
  static SegmentIndex of(Graph graph) {
    final cached = _cache[graph];
    if (cached != null && cached.revision == graph.revision) return cached;
    return _cache[graph] = SegmentIndex._(graph);
  }

  SegmentIndex._(Graph graph) : revision = graph.revision {
    for (final edges in graph.adjacencyList.values) {
      for (final edge in edges) {
        // Each undirected edge is stored in both directions; index it once.
        if (edge.from > edge.to) continue;
        final a = graph.nodes[edge.from];
        final b = graph.nodes[edge.to];
        if (a == null || b == null) continue;
        final x0 = _cell(min(a.lon, b.lon)), x1 = _cell(max(a.lon, b.lon));
        final y0 = _cell(min(a.lat, b.lat)), y1 = _cell(max(a.lat, b.lat));
        for (var x = x0; x <= x1; x++) {
          for (var y = y0; y <= y1; y++) {
            (_cells[_key(x, y)] ??= []).add(edge);
          }
        }
        _minX = min(_minX, x0);
        _maxX = max(_maxX, x1);
        _minY = min(_minY, y0);
        _maxY = max(_maxY, y1);
      }
    }
  }

  bool get isEmpty => _cells.isEmpty;

  static int _cell(double degrees) => (degrees / cellDegrees).floor();

  // Unique for |x|, |y| < 2^20 and within the web's 53-bit integers.
  static int _key(int x, int y) =>
      (x + (1 << 20)) * (1 << 21) + (y + (1 << 20));

  /// Visits segments around [position] in growing rings of cells.
  ///
  /// [visit] receives the segments first seen in each ring and returns the
  /// distance (meters) of the best match so far; the search stops once no
  /// unvisited cell can contain anything closer.
  void search(LatLng position, double Function(List<Edge> newEdges) visit) {
    final cx = _cell(position.longitude), cy = _cell(position.latitude);
    // Distance covered by one ring of cells (the shorter cell side).
    final ringMeters = cellDegrees *
        _metersPerDegree *
        min(1.0, cos(position.latitude * pi / 180).abs());
    final maxRing = [
      (cx - _minX).abs(),
      (_maxX - cx).abs(),
      (cy - _minY).abs(),
      (_maxY - cy).abs(),
    ].reduce(max);

    final seen = <Edge>{};
    var best = double.infinity;
    for (var ring = 0; ring <= maxRing; ring++) {
      final newEdges = <Edge>[];
      for (var x = cx - ring; x <= cx + ring; x++) {
        // Only the cells on the ring's border are new.
        final onSide = x == cx - ring || x == cx + ring;
        for (var y = cy - ring; y <= cy + ring; y += onSide ? 1 : 2 * ring) {
          for (final edge in _cells[_key(x, y)] ?? const <Edge>[]) {
            if (seen.add(edge)) newEdges.add(edge);
          }
        }
      }
      if (newEdges.isNotEmpty) best = visit(newEdges);
      // Anything outside rings 0..ring is at least ring * ringMeters away.
      if (best <= ring * ringMeters) break;
    }
  }
}
