// TODO Implement this library.

import 'dart:convert';

import 'package:trip_routing/src/models/edge.dart';
import 'package:trip_routing/src/utils/bounds_calculator.dart';
import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;


class TripService {
  Future<List<Map<String, dynamic>>> fetchWalkingPaths(
      double minLat, double minLon, double maxLat, double maxLon) async {
    final query = '''
    [out:json];
    (
      way["highway"]($minLat, $minLon, $maxLat, $maxLon);
    );
    out body;
    >;
    out skel qt;
    ''';

    final url = Uri.parse('https://overpass-api.de/api/interpreter');

    try {
      final response = await http.post(
        url,
        body: {'data': query},
      );

      if (response.statusCode == 200) {
        final rawData = jsonDecode(response.body) as Map<String, dynamic>;
        final data = (rawData['elements'] as List)
            .map((e) => {
                  'type': e['type'] ?? '',
                  'id': e['id'] ?? -1,
                  'lat': e['lat'] ?? 0.0,
                  'lon': e['lon'] ?? 0.0,
                  'tags': e['tags'] ?? {},
                  'nodes': e['nodes'] ?? [],
                })
            .toList();

        return data;
      } else {
        return [];
      }
    } catch (e) {
      return [];
    }
  }

Graph removeNodeIslands(Graph graph, int maxNodes) {
    final visited = <int>{};
    final connectedComponents = <List<int>>[];

    // Find connected components using DFS
    for (final nodeId in graph.nodes.keys) {
      if (!visited.contains(nodeId)) {
        final component = <int>[];
        _iterativeDfs(graph, nodeId, visited, component);
        connectedComponents.add(component);
      }
    }

    // Remove small components
    for (final component in connectedComponents) {
      if (component.length <= maxNodes) {
        for (final nodeId in component) {
          graph.removeNode(nodeId);
        }
      }
    }
    return graph;
  }

  void _iterativeDfs(
      Graph graph, int startNodeId, Set<int> visited, List<int> component) {
    final stack = <int>[startNodeId];

    while (stack.isNotEmpty) {
      final nodeId = stack.removeLast();

      if (visited.contains(nodeId)) continue;

      visited.add(nodeId);
      component.add(nodeId);

      final neighbors = graph.adjacencyList[nodeId] ?? [];
      for (final edge in neighbors) {
        if (!visited.contains(edge.to)) {
          stack.add(edge.to);
        }
      }
    }
  }

  Graph parseGraph(List elements, bool preferWalkingPaths) {
    var graph = Graph();
    for (final element in elements) {
      if (element['type'] == 'node') {
        final node = Node(
          element['id'] as int,
          element['lat'] as double,
          element['lon'] as double,
          false,
        );
        graph.addNode(node);
      }
    }

    // Extract ways as edges
    for (final element in elements) {
      if (element['type'] == 'way') {
        final nodes = element['nodes'] as List;

        
        final tags = element['tags'] as Map<String, dynamic>;
        var isFootWay = false;
        if(preferWalkingPaths){
          isFootWay = tags.containsKey('footway') ||
                      tags.containsKey('pedestrian') ||
                      tags.containsKey('footway');
        }    
        for (var i = 0; i < nodes.length - 1; i++) {
          if (isFootWay) {
            if (graph.nodes[nodes[i]] != null) {
              graph.nodes[nodes[i]]!.setIsFootWay = true;
            }
          }
          final startIndex = nodes[i] as int;
          final endIndex = nodes[i + 1] as int;

          final startNode = graph.nodes[startIndex];
          final endNode = graph.nodes[endIndex];
          if (startNode == null || endNode == null) {
            continue;
          }
          final edge = Edge(
              startIndex,
              endIndex,
              haversineDistance(
                  startNode.lat, startNode.lon, endNode.lat, endNode.lon));
          graph.addEdge(edge);
        }
      }
    }

    graph = removeNodeIslands(graph, 130);
    return graph;
  }

  List<int> findClosestNodes(Graph graph, List<LatLng> positions) {
    final closestNodeIds = <int>[];

    for (final position in positions) {
      var closestNodeId = -1;
      var minDistance = double.infinity;

      for (final node in graph.nodes.values) {
        final distance = haversineDistance(
            position.latitude, position.longitude, node.lat, node.lon);
        if (distance < minDistance) {
          minDistance = distance;
          closestNodeId = node.id;
        }
      }
      closestNodeIds.add(closestNodeId);
    }
    return closestNodeIds;
  }

   Trip shortestPath(Graph graph, int startId, int targetId) {
    final distances = <int, double>{};
    final previousNodes = <int, int>{};
    final visited = <int>{};

    // Priority queue using a binary heap
    final priorityQueue = PriorityQueue<MapEntry<int, double>>(
      (a, b) => a.value.compareTo(b.value),
    );

    // Initialize distances
    for (final nodeId in graph.nodes.keys) {
      distances[nodeId] = double.infinity;
    }
    distances[startId] = 0;
    priorityQueue.add(MapEntry(startId, 0));

    while (priorityQueue.isNotEmpty) {
      // Get the node with the smallest distance
      final currentNodeId = priorityQueue.removeFirst().key;

      // Mark as visited
      if (visited.contains(currentNodeId)) continue;
      visited.add(currentNodeId);

      // Stop if we've reached the target
      if (currentNodeId == targetId) break;

      // Update distances for neighbors
      for (final edge in graph.adjacencyList[currentNodeId]!) {
        if (visited.contains(edge.to)) continue;

        // Calculate distance
        final isFootWay = graph.nodes[edge.to]?.isFootWay ?? false;
        final footwayPenalty =
            isFootWay ? 0.95 : 1.0; // Prefer footways slightly
        final newDistance =
            distances[currentNodeId]! + edge.weight * footwayPenalty;

        // Relax the edge if a shorter path is found
        if (newDistance < distances[edge.to]!) {
          distances[edge.to] = newDistance;
          previousNodes[edge.to] = currentNodeId;

          // Push to priority queue
          priorityQueue.add(MapEntry(edge.to, newDistance));
        }
      }
    }

    // Reconstruct the shortest path
    final path = <int>[];
    var currentNodeId = targetId;
    while (previousNodes.containsKey(currentNodeId)) {
      path.add(currentNodeId);
      currentNodeId = previousNodes[currentNodeId]!;
    }
    if (currentNodeId == startId) path.add(startId);

    final route = path.reversed
        .toList()
        .map((a) => LatLng(graph.nodes[a]!.lat, graph.nodes[a]!.lon))
        .toList();
    return Trip(route: route, distance: distances[targetId]!);
  }

  Future<Trip> findTotalTrip(List<LatLng> waypoints, {bool preferWalkingPaths= true}) async {
    final totalRoute = <LatLng>[];
    var totalDistance = 0.0;
    final bounds = findLatLonBounds(waypoints);
    final fetchedData =
        await fetchWalkingPaths(bounds[0], bounds[1], bounds[2], bounds[3]);
    // After fetching and parsing the graph
    final graph = parseGraph(fetchedData, preferWalkingPaths); // Use the parsed graph
    final queryIds = findClosestNodes(graph, waypoints);
    for (var i = 0; i < queryIds.length - 1; i++) {
      final path = shortestPath(graph, queryIds[i], queryIds[i + 1]);
      if (path.route.isEmpty) {
        print('No path found between the points.');
        totalRoute.addAll([waypoints[i + 1]]);
        totalDistance += haversineDistance(
            waypoints[i].latitude,
            waypoints[i].longitude,
            waypoints[i + 1].latitude,
            waypoints[i + 1].longitude);
      } else {
        totalRoute.addAll(path.route);
        totalDistance += path.distance;
      }
    }
    return Trip(route: totalRoute, distance: totalDistance);
  }
}
