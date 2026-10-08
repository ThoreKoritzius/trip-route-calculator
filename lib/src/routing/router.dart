import 'dart:math';

import 'package:collection/collection.dart';
import 'package:latlong2/latlong.dart';

import '../models/edge.dart';
import '../models/graph.dart';
import '../utils/haversine.dart';
import 'snapping.dart';

/// Cost model for pedestrian routing.
class RouteCosts {
  /// Whether edges on dedicated walking ways get [footwayCostFactor].
  final bool preferWalkingPaths;

  /// Cost multiplier for walking-way edges when [preferWalkingPaths] is set.
  final double footwayCostFactor;

  /// Whether stairs get [stepsCostFactor] (e.g. for wheelchairs/strollers).
  final bool avoidSteps;

  /// Cost multiplier for `highway=steps` edges when [avoidSteps] is set.
  final double stepsCostFactor;

  /// Extra cost (meters) whenever an edge used by a previous leg is reused.
  final double duplicationPenalty;

  const RouteCosts({
    this.preferWalkingPaths = true,
    this.footwayCostFactor = 0.9,
    this.avoidSteps = false,
    this.stepsCostFactor = 5.0,
    this.duplicationPenalty = 0.0,
  });

  double factor(Edge edge) {
    var f = 1.0;
    if (preferWalkingPaths && edge.isFootWay) f *= footwayCostFactor;
    if (avoidSteps && edge.isSteps) f *= stepsCostFactor;
    return f;
  }
}

/// A routed leg between two snapped positions.
class RouteResult {
  final List<LatLng> route;

  /// Length of [route] in meters.
  final double distance;

  RouteResult(this.route, this.distance);
}

/// Direction-independent key, so traversing an edge back counts as reuse.
(int, int) edgeKey(int a, int b) => a < b ? (a, b) : (b, a);

/// Finds the cheapest route from [start] to [target] (A* search).
///
/// Routes may start and end part-way along a segment. Edges of the returned
/// route are added to [usedEdges]; edges already in it cost an additional
/// [RouteCosts.duplicationPenalty]. Returns `null` if [target] is unreachable.
RouteResult? routeBetween(
  Graph graph,
  GraphSnap start,
  GraphSnap target,
  RouteCosts costs, {
  Set<(int, int)>? usedEdges,
}) {
  // Cost of walking [length] meters of [edge]. Partially walked segments
  // (at the start/end of a leg) pay a proportional share of the penalty.
  double cost(Edge edge, double length) {
    final weight = (length.isFinite && length >= 0) ? length : 0.0;
    var penalty = 0.0;
    if (usedEdges != null &&
        costs.duplicationPenalty > 0 &&
        usedEdges.contains(edgeKey(edge.from, edge.to))) {
      penalty = costs.duplicationPenalty *
          (edge.weight > 0 ? (weight / edge.weight).clamp(0.0, 1.0) : 1.0);
    }
    return weight * costs.factor(edge) + penalty;
  }

  // Entry points into the network: (node, weighted cost, actual length).
  final sources = <(int, double, double)>[];
  final targets = <int, (double, double)>{};
  final startEdge = start.edge;
  if (startEdge == null) {
    sources.add((start.nodeId!, 0, 0));
  } else {
    final toFrom = startEdge.weight * start.fraction;
    final toTo = startEdge.weight - toFrom;
    sources.add((startEdge.from, cost(startEdge, toFrom), toFrom));
    sources.add((startEdge.to, cost(startEdge, toTo), toTo));
  }
  final targetEdge = target.edge;
  if (targetEdge == null) {
    targets[target.nodeId!] = (0, 0);
  } else {
    final fromFrom = targetEdge.weight * target.fraction;
    final fromTo = targetEdge.weight - fromFrom;
    targets[targetEdge.from] = (cost(targetEdge, fromFrom), fromFrom);
    targets[targetEdge.to] = (cost(targetEdge, fromTo), fromTo);
  }

  var bestCost = double.infinity;
  var bestLength = 0.0;
  int? bestEnd;
  var direct = false;

  // Both positions on the same segment: walking along it directly.
  if (startEdge != null &&
      targetEdge != null &&
      edgeKey(startEdge.from, startEdge.to) ==
          edgeKey(targetEdge.from, targetEdge.to)) {
    final targetFraction = targetEdge.from == startEdge.from
        ? target.fraction
        : 1 - target.fraction;
    final length = (targetFraction - start.fraction).abs() * startEdge.weight;
    bestCost = cost(startEdge, length);
    bestLength = length;
    direct = true;
  } else if (start.point == target.point) {
    return RouteResult([start.point], 0);
  }

  // A* towards the target point. The straight-line distance times the
  // cheapest possible cost factor never overestimates the remaining cost
  // (tails and penalties are non-negative), so results stay optimal.
  final minFactor = [
    1.0,
    if (costs.preferWalkingPaths) costs.footwayCostFactor,
    if (costs.avoidSteps) costs.stepsCostFactor,
  ].reduce(min);
  final targetLat = target.point.latitude, targetLon = target.point.longitude;
  double heuristic(int nodeId) {
    final node = graph.nodes[nodeId]!;
    return minFactor *
        haversineDistance(node.lat, node.lon, targetLat, targetLon);
  }

  final weighted = <int, double>{};
  final actual = <int, double>{};
  final previous = <int, int>{};
  final visited = <int>{};
  // Entries are (node, cost so far + heuristic).
  final queue = PriorityQueue<(int, double)>((a, b) => a.$2.compareTo(b.$2));
  for (final (node, weightedCost, length) in sources) {
    if (weightedCost < (weighted[node] ?? double.infinity)) {
      weighted[node] = weightedCost;
      actual[node] = length;
      queue.add((node, weightedCost + heuristic(node)));
    }
  }

  while (queue.isNotEmpty) {
    final (current, estimate) = queue.removeFirst();
    // No remaining route can beat the best one found so far.
    if (estimate >= bestCost) break;
    if (!visited.add(current)) continue;
    final currentCost = weighted[current]!;

    final tail = targets[current];
    if (tail != null && currentCost + tail.$1 < bestCost) {
      bestCost = currentCost + tail.$1;
      bestLength = actual[current]! + tail.$2;
      bestEnd = current;
      direct = false;
    }

    for (final edge in graph.adjacencyList[current] ?? const <Edge>[]) {
      if (visited.contains(edge.to)) continue;
      final newCost = currentCost + cost(edge, edge.weight);
      if (newCost < (weighted[edge.to] ?? double.infinity)) {
        weighted[edge.to] = newCost;
        actual[edge.to] = actual[current]! + edge.weight;
        previous[edge.to] = current;
        queue.add((edge.to, newCost + heuristic(edge.to)));
      }
    }
  }

  if (direct) {
    usedEdges?.add(edgeKey(startEdge!.from, startEdge.to));
    return RouteResult(
        start.point == target.point
            ? [start.point]
            : [start.point, target.point],
        bestLength);
  }
  if (bestEnd == null) return null;

  final path = <int>[bestEnd];
  while (previous.containsKey(path.last)) {
    path.add(previous[path.last]!);
  }
  final nodeIds = path.reversed.toList();

  if (usedEdges != null) {
    for (var i = 0; i < nodeIds.length - 1; i++) {
      usedEdges.add(edgeKey(nodeIds[i], nodeIds[i + 1]));
    }
    if (startEdge != null) usedEdges.add(edgeKey(startEdge.from, startEdge.to));
    if (targetEdge != null) {
      usedEdges.add(edgeKey(targetEdge.from, targetEdge.to));
    }
  }

  final route = <LatLng>[start.point];
  void append(LatLng p) {
    if (route.last != p) route.add(p);
  }

  for (final id in nodeIds) {
    final node = graph.nodes[id]!;
    append(LatLng(node.lat, node.lon));
  }
  append(target.point);
  return RouteResult(route, bestLength);
}
