import '../models/edge.dart';
import '../models/graph.dart';
import '../models/node.dart';
import 'haversine.dart';

/// `highway=*` values that count as dedicated walking ways.
const footWayHighways = {
  'footway',
  'pedestrian',
  'path',
  'steps',
  'living_street',
};

const _noAccess = {'no', 'private'};
const _footAllowed = {'yes', 'designated', 'permissive'};

/// Whether pedestrians may use a way with the given OSM [tags].
///
/// `foot=*` overrides the general `access=*` restriction, so e.g.
/// `access=no` + `foot=yes` stays walkable.
bool isWalkable(Map tags) {
  final foot = tags['foot'];
  if (_noAccess.contains(foot)) return false;
  if (_noAccess.contains(tags['access'])) return _footAllowed.contains(foot);
  return true;
}

/// Builds a routing graph from raw Overpass `elements` (nodes and ways).
///
/// Connected components with at most [minIslandSize] nodes are removed so
/// waypoints do not snap onto disconnected fragments. The largest component
/// is always kept, so small bounding boxes never end up with an empty graph.
Graph buildGraphFromOsmElements(List<dynamic> elements,
    {int minIslandSize = 100}) {
  final graph = Graph();

  for (final element in elements) {
    if (element is! Map || element['type'] != 'node') continue;
    final id = element['id'];
    final lat = element['lat'];
    final lon = element['lon'];
    if (id is int && lat is num && lon is num && lat.isFinite && lon.isFinite) {
      graph.addNode(Node(id, lat.toDouble(), lon.toDouble(), false));
    }
  }

  for (final element in elements) {
    if (element is! Map || element['type'] != 'way') continue;
    final nodes = element['nodes'];
    if (nodes is! List) continue;
    final tags = element['tags'] is Map ? element['tags'] as Map : const {};
    if (!isWalkable(tags)) continue;
    final isFootWay = footWayHighways.contains(tags['highway']) ||
        tags['footway'] != null ||
        tags['foot'] == 'designated';
    final isSteps = tags['highway'] == 'steps';

    for (int i = 0; i < nodes.length - 1; i++) {
      final startNode = graph.nodes[nodes[i]];
      final endNode = graph.nodes[nodes[i + 1]];
      if (startNode == null || endNode == null || startNode == endNode) {
        continue;
      }
      if (isFootWay) {
        startNode.isFootWay = true;
        endNode.isFootWay = true;
      }
      final dist = haversineDistance(
          startNode.lat, startNode.lon, endNode.lat, endNode.lon);
      graph.addEdge(Edge(startNode.id, endNode.id, dist.isFinite ? dist : 0.0,
          isFootWay: isFootWay, isSteps: isSteps));
    }
  }

  removeSmallIslands(graph, minIslandSize);
  return graph;
}

/// Removes connected components with at most [maxNodes] nodes, except the
/// largest component.
void removeSmallIslands(Graph graph, int maxNodes) {
  final visited = <int>{};
  final components = <List<int>>[];

  for (final nodeId in graph.nodes.keys) {
    if (visited.contains(nodeId)) continue;
    final component = <int>[];
    final stack = <int>[nodeId];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (!visited.add(current)) continue;
      component.add(current);
      for (final edge in graph.adjacencyList[current] ?? const <Edge>[]) {
        if (!visited.contains(edge.to)) stack.add(edge.to);
      }
    }
    components.add(component);
  }
  if (components.isEmpty) return;

  final largest = components.reduce((a, b) => a.length >= b.length ? a : b);
  for (final component in components) {
    if (component.length <= maxNodes && !identical(component, largest)) {
      component.forEach(graph.removeNode);
    }
  }
}
