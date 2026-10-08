import 'dart:math';

import 'package:latlong2/latlong.dart';

import '../models/edge.dart';
import '../models/graph.dart';
import '../models/node.dart';
import '../utils/haversine.dart';
import 'spatial_index.dart';

/// A position projected onto the routing network.
class GraphSnap {
  /// The projected point on the network.
  final LatLng point;

  /// Straight-line distance in meters from the queried position to [point].
  final double distance;

  /// The segment the point lies on, or `null` when snapped onto a node
  /// without edges.
  final Edge? edge;

  /// Position along [edge]: 0 at `edge.from`, 1 at `edge.to`.
  final double fraction;

  /// Node id used when [edge] is `null`.
  final int? nodeId;

  GraphSnap._(this.point, this.distance, this.edge, this.fraction, this.nodeId);

  /// A snap exactly onto the node [node].
  factory GraphSnap.atNode(Node node) =>
      GraphSnap._(LatLng(node.lat, node.lon), 0, null, 0, node.id);

  @override
  String toString() =>
      'GraphSnap($point, ${distance.toStringAsFixed(1)} m, edge: $edge, fraction: $fraction)';
}

/// Projects [position] onto the closest segment of [graph].
///
/// Uses a spatial index that is built on first use and rebuilt after the
/// graph changes (see [Graph.revision]). Returns `null` for an empty graph.
GraphSnap? snapToGraph(Graph graph, LatLng position) {
  final index = SegmentIndex.of(graph);
  if (index.isEmpty) {
    return snapToEdges(graph, position, const [], () => graph.nodes.values);
  }
  GraphSnap? best;
  index.search(position, (edges) {
    final snap = snapToEdges(graph, position, edges, () => const []);
    if (snap != null && (best == null || snap.distance < best!.distance)) {
      best = snap;
    }
    return best?.distance ?? double.infinity;
  });
  return best;
}

/// Like [snapToGraph], but only considers [candidates]; [allNodes] is used as
/// a fallback when there are no candidate edges.
GraphSnap? snapToEdges(Graph graph, LatLng position, Iterable<Edge> candidates,
    Iterable<Node> Function() allNodes) {
  // Local equirectangular projection around the position (meters).
  const metersPerDegree = 6371e3 * pi / 180;
  final lat0 = position.latitude;
  final lon0 = position.longitude;
  final lonScale = cos(lat0 * pi / 180) * metersPerDegree;
  double x(double lon) => (lon - lon0) * lonScale;
  double y(double lat) => (lat - lat0) * metersPerDegree;

  Edge? bestEdge;
  var bestFraction = 0.0;
  var bestDistanceSq = double.infinity;

  for (final edge in candidates) {
    // Each undirected edge is stored in both directions; check it once.
    if (edge.from > edge.to) continue;
    final a = graph.nodes[edge.from];
    final b = graph.nodes[edge.to];
    if (a == null || b == null) continue;
    final ax = x(a.lon), ay = y(a.lat);
    final dx = x(b.lon) - ax, dy = y(b.lat) - ay;
    final lengthSq = dx * dx + dy * dy;
    final t =
        lengthSq == 0 ? 0.0 : (-(ax * dx + ay * dy) / lengthSq).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final distanceSq = px * px + py * py;
    if (distanceSq < bestDistanceSq) {
      bestDistanceSq = distanceSq;
      bestEdge = edge;
      bestFraction = t;
    }
  }

  if (bestEdge == null) {
    Node? nearest;
    var nearestDistance = double.infinity;
    for (final node in allNodes()) {
      final d = haversineDistance(lat0, lon0, node.lat, node.lon);
      if (d < nearestDistance) {
        nearestDistance = d;
        nearest = node;
      }
    }
    if (nearest == null) return null;
    final snap = GraphSnap.atNode(nearest);
    return GraphSnap._(snap.point, nearestDistance, null, 0, nearest.id);
  }

  final a = graph.nodes[bestEdge.from]!;
  final b = graph.nodes[bestEdge.to]!;
  // Use the exact node coordinates at the ends so routes join cleanly.
  final point = bestFraction <= 0
      ? LatLng(a.lat, a.lon)
      : bestFraction >= 1
          ? LatLng(b.lat, b.lon)
          : LatLng(a.lat + bestFraction * (b.lat - a.lat),
              a.lon + bestFraction * (b.lon - a.lon));
  return GraphSnap._(
      point,
      haversineDistance(lat0, lon0, point.latitude, point.longitude),
      bestEdge,
      bestFraction,
      null);
}
