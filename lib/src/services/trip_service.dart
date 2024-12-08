import 'dart:convert';
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;

class TripService {
  final entranceFinder = BuildingAndEntranceFinder();
  var currentCity;
  var graph = Graph();
  Future<List<Map<String, dynamic>>> _fetchWalkingPaths(
      double minLat, double minLon, double maxLat, double maxLon) async {
    final query = '''
    [out:json];
    (
      way["highway"]["area"!~"yes"]["place"!~"square"]($minLat, $minLon, $maxLat, $maxLon);
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

  Graph _removeNodeIslands(Graph graph, int maxNodes) {
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

  Graph _parseGraph(List elements, bool preferWalkingPaths) {
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
        if (preferWalkingPaths) {
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

    graph = _removeNodeIslands(graph, 100);
    return graph;
  }

  List<int> _findClosestNodes(Graph graph, List<LatLng> positions) {
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
    final actualDistances = <int, double>{};
    final weightedDistances =
        <int, double>{}; // Weighted distances for preference
    final previousNodes = <int, int>{};
    final visited = <int>{};

    // Priority queue using a binary heap
    final priorityQueue = PriorityQueue<MapEntry<int, double>>(
      (a, b) => a.value.compareTo(b.value),
    );

    // Initialize distances
    for (final nodeId in graph.nodes.keys) {
      actualDistances[nodeId] = double.infinity;
      weightedDistances[nodeId] = double.infinity;
    }
    actualDistances[startId] = 0;
    weightedDistances[startId] = 0;
    priorityQueue.add(MapEntry(startId, 0));

    while (priorityQueue.isNotEmpty) {
      // Get the node with the smallest weighted distance
      final currentNodeId = priorityQueue.removeFirst().key;

      // Mark as visited
      if (visited.contains(currentNodeId)) continue;
      visited.add(currentNodeId);

      // Stop if we've reached the target
      if (currentNodeId == targetId) break;

      // Update distances for neighbors
      for (final edge in graph.adjacencyList[currentNodeId]!) {
        if (visited.contains(edge.to)) continue;

        // Calculate distances
        final isFootWay = graph.nodes[edge.to]?.isFootWay ?? false;
        final footwayPenalty = isFootWay ? 0.95 : 1.0;
        final newActualDistance = actualDistances[currentNodeId]! + edge.weight;
        final newWeightedDistance =
            weightedDistances[currentNodeId]! + edge.weight * footwayPenalty;

        // Relax the edge if a shorter weighted path is found
        if (newWeightedDistance < weightedDistances[edge.to]!) {
          actualDistances[edge.to] = newActualDistance;
          weightedDistances[edge.to] = newWeightedDistance;
          previousNodes[edge.to] = currentNodeId;

          // Push to priority queue
          priorityQueue.add(MapEntry(edge.to, newWeightedDistance));
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
    return Trip(
      route: route,
      distance: actualDistances[targetId] ?? double.infinity,
      errors: [],
    );
  }

  Trip _findGlobalShortestPath(
    Graph graph,
    int startId,
    int targetId,
    double duplicationPenalty,
    Set<String> usedEdges,
  ) {
    final actualDistances = <int, double>{};
    final weightedDistances = <int, double>{};
    final previousNodes = <int, int>{};
    final visited = <int>{};
    final priorityQueue = PriorityQueue<MapEntry<int, double>>(
      (a, b) => a.value.compareTo(b.value),
    );

    // Initialize distances
    for (final nodeId in graph.nodes.keys) {
      actualDistances[nodeId] = double.infinity;
      weightedDistances[nodeId] = double.infinity;
    }
    actualDistances[startId] = 0;
    weightedDistances[startId] = 0;
    priorityQueue.add(MapEntry(startId, 0));

    while (priorityQueue.isNotEmpty) {
      final currentNodeId = priorityQueue.removeFirst().key;

      if (visited.contains(currentNodeId)) continue;
      visited.add(currentNodeId);

      if (currentNodeId == targetId) break;

      for (final edge in graph.adjacencyList[currentNodeId]!) {
        if (visited.contains(edge.to)) continue;

        // Calculate edge key and penalty
        final edgeKey = '${edge.from}-${edge.to}';
        final edgePenalty =
            usedEdges.contains(edgeKey) ? duplicationPenalty : 0.0;

        final isFootWay = graph.nodes[edge.to]?.isFootWay ?? false;
        final footwayPenalty = isFootWay ? 0.95 : 1.0;

        final newActualDistance = actualDistances[currentNodeId]! + edge.weight;
        final newWeightedDistance = weightedDistances[currentNodeId]! +
            edge.weight * footwayPenalty +
            edgePenalty;

        if (newWeightedDistance < weightedDistances[edge.to]!) {
          actualDistances[edge.to] = newActualDistance;
          weightedDistances[edge.to] = newWeightedDistance;
          previousNodes[edge.to] = currentNodeId;

          priorityQueue.add(MapEntry(edge.to, newWeightedDistance));
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

    // Track edges globally
    for (var i = 0; i < path.length - 1; i++) {
      usedEdges.add('${path[i]}-${path[i + 1]}');
    }

    return Trip(
      route: route,
      distance: actualDistances[targetId] ?? double.infinity,
      errors: [],
    );
  }

  /// Calculates the total trip route and distance between any given waypoints.
  ///
  /// This function computes the optimal path between a list of waypoints, optionally adjusting the
  /// route based on walking paths or building entrances.
  ///
  /// Parameters:
  ///   - [waypoints]: A list of `LatLng` objects representing the locations (latitude and longitude)
  ///     between which the route needs to be calculated.
  ///   - [preferWalkingPaths]: Bool flag indicating whether walking paths should be preferred
  ///     over other types of paths. Defaults to `true`.
  ///   - [replaceWaypointsWithBuildingEntrances]: Boolean flag that determines if waypoints should
  ///     be replaced with building entrances. If no entrance is found, the original waypoint is not replaced. Defaults to `false`.
  ///   - [forceIncludeWaypoints]: Boolean flag that forces the inclusion of waypoints in the final
  ///     route even if they are not exactly on a road. Defaults to `false`.
  ///
  /// Returns:
  ///   A `Future<Trip>` representing the total trip, including:
  ///   - [route]: List of `LatLng` locations representing the full trip route from start to destination.
  ///   - [distance]: `double`, representing the total distance of the trip in meters.
  ///   - [errors]: List of `String` containing error messages encountered during route calculation.
  ///   - [duplicationPenalty]: penalty term to prefer no duplicate ways in global trip
  Future<Trip> findTotalTrip(List<LatLng> waypoints,
      {bool preferWalkingPaths = true,
      bool replaceWaypointsWithBuildingEntrances = false,
      bool forceIncludeWaypoints = false,
      double duplicationPenalty = 0.0}) async {
    var totalRoute = <LatLng>[];
    var totalDistance = 0.0;
    var errors = <String>[];
    List<bool> foundEntrance = [];
    List<double>? bounds;
    if (currentCity == null) {
      //non-offline mode
      bounds = findLatLonBounds(waypoints);
      if (replaceWaypointsWithBuildingEntrances) {
        waypoints =
            await _replaceWaypointsWithEntrances(waypoints, foundEntrance);
      } else {
        foundEntrance = List<bool>.filled(waypoints.length, false);
      }
      graph = await _fetchGraph(bounds, preferWalkingPaths);
    } else {
      foundEntrance = List<bool>.filled(waypoints.length, false);
    }

    final usedEdges = <String>{}; // Track edges globally across all subtrips
    final queryIds = _findClosestNodes(graph, waypoints);
    for (var i = 0; i < queryIds.length - 1; i++) {
      final subTrip = _findGlobalShortestPath(
        graph,
        queryIds[i],
        queryIds[i + 1],
        duplicationPenalty,
        usedEdges,
      );

      totalRoute.addAll(subTrip.route);
      totalDistance += subTrip.distance;

      // Add waypoints back to the route if necessary
      if (_shouldAddWaypoint(
          subTrip, foundEntrance, forceIncludeWaypoints, i)) {
        totalRoute.add(waypoints[i + 1]);
      }
    }

    return Trip(
        route: totalRoute,
        distance: totalDistance,
        errors: errors,
        boundingBox: bounds);
  }

  // Helper method to replace waypoints with building entrances
  Future<List<LatLng>> _replaceWaypointsWithEntrances(
      List<LatLng> waypoints, List<bool> foundEntrance) async {
    // Call the modified findBuildingAndEntrance to get all entrances for the waypoints in the bounding box
    List<LatLng> entrances =
        await entranceFinder.findBuildingAndEntrance(waypoints);

    var updatedWaypoints = <LatLng>[];

    // For each waypoint, check if an entrance is found and update accordingly
    for (int i = 0; i < waypoints.length; i++) {
      var point = waypoints[i];
      var updatedPoint = entrances.isNotEmpty ? entrances[i] : point;
      updatedWaypoints.add(updatedPoint);
      foundEntrance.add(updatedPoint !=
          point);
    }

    return updatedWaypoints;
  }

  // Helper method to fetch graph data and parse it
  Future<Graph> _fetchGraph(
      List<double> bounds, bool preferWalkingPaths) async {
    var fetchedData =
        await _fetchWalkingPaths(bounds[0], bounds[1], bounds[2], bounds[3]);
    return _parseGraph(fetchedData, preferWalkingPaths);
  }

  // Helper method to determine whether to add a waypoint to the route
  bool _shouldAddWaypoint(Trip subTrip, List<bool> foundEntrance,
      bool forceIncludeWaypoints, int index) {
    return forceIncludeWaypoints ||
        (foundEntrance[index + 1] && subTrip.route.isNotEmpty);
  }

  Future<String> getCityPath(String cityName) async {
    // final Directory appDir = await getApplicationDocumentsDirectory();
    // return '${appDir.path}/$cityName_graph.json';
    return '$cityName.json';
  }

  /// Downloads routing data for a specified city and uses the cached file for future routing.
  /// Note: offline routing doesnt allow to handle `replaceWaypointsWithBuildingEntrances`
  ///
  /// Parameters:
  /// - [cityName]: The name of the city for which routing data is being prepared.
  ///
  /// Returns:
  /// - A `Future<bool>` indicating whether the operation was successful:
  ///   - `true`: Routing data was successfully loaded or downloaded.
  ///   - `false`: An error occurred while fetching the bounding box
  ///
  Future<bool> useCity(String cityName) async {
    final filePath = await getCityPath(cityName);
    try {
      graph = await graph.loadGraph(filePath);
      currentCity = cityName;
    } catch (e) {
      final boundingBox = await _fetchBoundingBox(cityName);
      if (boundingBox == null) {
        print('Could not fetch bounding box for $cityName.');
        return false;
      }
      currentCity = cityName;
      final minLat = boundingBox['minLat']!;
      final minLon = boundingBox['minLon']!;
      final maxLat = boundingBox['maxLat']!;
      final maxLon = boundingBox['maxLon']!;
      graph = await _fetchGraph([minLat, minLon, maxLat, maxLon], true);
      await graph.saveGraph(filePath);
    }
    return true;
  }

  Future<Map<String, double>?> _fetchBoundingBox(String city) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?city=$city&format=json&limit=1');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List;
        if (results.isNotEmpty) {
          final result = results[0];
          return {
            'minLat': double.parse(result['boundingbox'][0]),
            'maxLat': double.parse(result['boundingbox'][1]),
            'minLon': double.parse(result['boundingbox'][2]),
            'maxLon': double.parse(result['boundingbox'][3]),
          };
        }
      }
    } catch (e) {
      print('Error fetching bounding box: $e');
    }
    return null;
  }
}
