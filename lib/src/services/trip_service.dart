import 'package:latlong2/latlong.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';

/// TripService provides routing and trip planning over OSM and cached city graphs.
///
/// Main entrypoint: [findTotalTrip].
class TripService {
  /// Cost multiplier for edges on dedicated walking ways when
  /// `preferWalkingPaths` is enabled.
  static const double footwayCostFactor = 0.95;

  /// Minimum padding (in degrees, ~500 m) around the waypoints when fetching
  /// online data, so nearby or collinear waypoints still get a usable area.
  static const double minBoundsPaddingDegrees = 0.005;

  final OsmClient _osm;
  final BuildingAndEntranceFinder entranceFinder;

  /// If not null, current offline city name.
  String? currentCity;

  /// The graph used for routing. Set by [useCity] for offline routing and
  /// updated with the fetched data on every online [findTotalTrip] call.
  Graph graph = Graph();

  /// [httpClient] can be supplied to customise networking (e.g. for tests).
  TripService({http.Client? httpClient, OsmClient? osmClient})
      : this._(osmClient ?? OsmClient(client: httpClient));

  TripService._(this._osm)
      : entranceFinder = BuildingAndEntranceFinder(osmClient: _osm);

  /// Compute the shortest path between two graph nodes, optionally preferring
  /// walking paths.
  ///
  /// Returns a [Trip] with empty route and `distance = 0.0` if route cannot be found.
  Trip shortestPath(Graph graph, int startId, int targetId,
      {bool preferWalkingPaths = true}) {
    return _shortestPath(graph, startId, targetId,
        preferWalkingPaths: preferWalkingPaths);
  }

  /// Dijkstra over [graph]. Edges in [usedEdges] cost an extra
  /// [duplicationPenalty]; the edges of the found path are added to it.
  Trip _shortestPath(
    Graph graph,
    int startId,
    int targetId, {
    required bool preferWalkingPaths,
    double duplicationPenalty = 0.0,
    Set<(int, int)>? usedEdges,
  }) {
    if (!graph.nodes.containsKey(startId) ||
        !graph.nodes.containsKey(targetId)) {
      return Trip(
          route: [], distance: 0.0, errors: ['Start/target node not found.']);
    }
    if (startId == targetId) {
      final node = graph.nodes[startId]!;
      return Trip(
          route: [LatLng(node.lat, node.lon)], distance: 0.0, errors: []);
    }

    final actualDistances = <int, double>{startId: 0.0};
    final weightedDistances = <int, double>{startId: 0.0};
    final previousNodes = <int, int>{};
    final visited = <int>{};
    final priorityQueue = PriorityQueue<(int, double)>(
      (a, b) => a.$2.compareTo(b.$2),
    )..add((startId, 0.0));

    while (priorityQueue.isNotEmpty) {
      final currentNodeId = priorityQueue.removeFirst().$1;
      if (!visited.add(currentNodeId)) continue;
      if (currentNodeId == targetId) break;

      for (final edge in graph.adjacencyList[currentNodeId] ?? const <Edge>[]) {
        if (visited.contains(edge.to)) continue;

        final weight =
            (edge.weight.isFinite && edge.weight >= 0) ? edge.weight : 0.0;
        final factor =
            preferWalkingPaths && edge.isFootWay ? footwayCostFactor : 1.0;
        final penalty = usedEdges != null &&
                duplicationPenalty > 0 &&
                usedEdges.contains(_edgeKey(edge.from, edge.to))
            ? duplicationPenalty
            : 0.0;
        final newWeightedDistance =
            weightedDistances[currentNodeId]! + weight * factor + penalty;

        if (newWeightedDistance <
            (weightedDistances[edge.to] ?? double.infinity)) {
          actualDistances[edge.to] = actualDistances[currentNodeId]! + weight;
          weightedDistances[edge.to] = newWeightedDistance;
          previousNodes[edge.to] = currentNodeId;
          priorityQueue.add((edge.to, newWeightedDistance));
        }
      }
    }

    if (!previousNodes.containsKey(targetId)) {
      return Trip(route: [], distance: 0.0, errors: ['No path found.']);
    }

    // Reconstruct the path (start -> target)
    final path = <int>[targetId];
    while (path.last != startId) {
      path.add(previousNodes[path.last]!);
    }
    final orderedPath = path.reversed.toList();

    if (usedEdges != null) {
      for (var i = 0; i < orderedPath.length - 1; i++) {
        usedEdges.add(_edgeKey(orderedPath[i], orderedPath[i + 1]));
      }
    }

    return Trip(
      route: [
        for (final id in orderedPath)
          LatLng(graph.nodes[id]!.lat, graph.nodes[id]!.lon)
      ],
      distance: actualDistances[targetId]!,
      errors: [],
    );
  }

  /// Direction-independent key, so traversing an edge back counts as reuse.
  (int, int) _edgeKey(int a, int b) => a < b ? (a, b) : (b, a);

  /// Find the closest node id in graph for each position.
  List<int> _findClosestNodes(Graph graph, List<LatLng> positions) {
    return [
      for (final position in positions)
        minBy<Node, double>(
                graph.nodes.values,
                (node) => haversineDistance(
                    position.latitude, position.longitude, node.lat, node.lon))!
            .id
    ];
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
  ///   - [duplicationPenalty]: penalty term (in meters) added each time an
  ///     edge already used by a previous leg is reused.
  ///
  /// Returns:
  ///   A `Future<Trip>` representing the total trip, including:
  ///   - [route]: List of `LatLng` locations representing the full trip route from start to destination.
  ///   - [distance]: `double`, representing the total distance of the trip in meters.
  ///   - [errors]: List of `String` containing error messages encountered during route calculation.
  Future<Trip> findTotalTrip(
    List<LatLng> waypoints, {
    bool preferWalkingPaths = true,
    bool replaceWaypointsWithBuildingEntrances = false,
    bool forceIncludeWaypoints = false,
    double duplicationPenalty = 0.0,
  }) async {
    if (waypoints.length < 2) {
      return Trip(
          route: List.of(waypoints),
          distance: 0.0,
          errors: ['At least two waypoints are required.']);
    }

    List<double>? bounds;
    var routingGraph = graph;
    var foundEntrance = List.filled(waypoints.length, false);

    // ONLINE mode: build the graph from the waypoints' bounding box
    if (currentCity == null) {
      if (replaceWaypointsWithBuildingEntrances) {
        final entrances =
            await entranceFinder.findBuildingAndEntrance(waypoints);
        if (entrances.length == waypoints.length) {
          foundEntrance = [
            for (var i = 0; i < waypoints.length; i++)
              entrances[i] != waypoints[i]
          ];
          waypoints = entrances;
        }
      }
      bounds = findLatLonBounds(waypoints,
          minPaddingDegrees: minBoundsPaddingDegrees);
      try {
        routingGraph = await _fetchGraph(bounds);
      } on OsmRequestException catch (e) {
        return Trip(
            route: [],
            distance: 0.0,
            errors: ['Graph data unavailable: ${e.message}'],
            boundingBox: bounds);
      }
      // Kept for backwards compatibility; routing below uses the local graph
      // so concurrent calls cannot interfere with each other.
      graph = routingGraph;
    }

    if (routingGraph.nodes.isEmpty) {
      return Trip(
          route: [],
          distance: 0.0,
          errors: ['Graph data unavailable'],
          boundingBox: bounds);
    }

    final totalRoute = <LatLng>[];
    var totalDistance = 0.0;
    final errors = <String>[];
    final usedEdges = <(int, int)>{};
    final queryIds = _findClosestNodes(routingGraph, waypoints);

    if (forceIncludeWaypoints || foundEntrance.first) {
      totalRoute.add(waypoints.first);
    }

    for (var i = 0; i < queryIds.length - 1; i++) {
      final subTrip = _shortestPath(
        routingGraph,
        queryIds[i],
        queryIds[i + 1],
        preferWalkingPaths: preferWalkingPaths,
        duplicationPenalty: duplicationPenalty,
        usedEdges: usedEdges,
      );

      if (subTrip.errors.isNotEmpty) {
        errors.addAll(subTrip.errors.map((e) => 'Leg ${i + 1}: $e'));
      }

      // Skip the first point when it repeats the end of the previous leg.
      final legRoute = subTrip.route;
      final skipFirst = totalRoute.isNotEmpty &&
          legRoute.isNotEmpty &&
          legRoute.first == totalRoute.last;
      totalRoute.addAll(skipFirst ? legRoute.skip(1) : legRoute);
      totalDistance += subTrip.distance;

      if (subTrip.route.isNotEmpty &&
          (forceIncludeWaypoints || foundEntrance[i + 1])) {
        totalRoute.add(waypoints[i + 1]);
      }
    }

    return Trip(
        route: totalRoute,
        distance: totalDistance,
        errors: errors,
        boundingBox: bounds);
  }

  /// Fetch and parse the OSM graph in a bounding box.
  Future<Graph> _fetchGraph(List<double> bounds) async {
    final elements = await _osm.fetchWalkableWays(
        bounds[0], bounds[1], bounds[2], bounds[3]);
    return buildGraphFromOsmElements(elements);
  }

  /// Get the data path for this city name. (Override for specific platforms.)
  Future<String> getCityPath(String cityName) async => '$cityName.json';

  /// Downloads routing data for a specified city and uses the cached file for future routing.
  /// Note: offline routing doesnt allow to handle `replaceWaypointsWithBuildingEntrances`
  ///
  /// Parameters:
  /// - [cityName]: The name of the city for which routing data is being prepared.
  ///
  /// Returns:
  /// - A `Future<bool>` indicating whether the operation was successful:
  ///   - `true`: Routing data was successfully loaded or downloaded.
  ///   - `false`: The city could not be found or its data could not be fetched.
  ///     The service then stays in its previous mode.
  Future<bool> useCity(String cityName) async {
    final filePath = await getCityPath(cityName);
    try {
      final cached = await Graph.fromFile(filePath);
      if (cached.nodes.isNotEmpty) {
        graph = cached;
        currentCity = cityName;
        return true;
      }
    } catch (_) {
      // No usable cache, download below.
    }

    final Graph downloaded;
    try {
      final bounds = await _osm.fetchCityBounds(cityName);
      if (bounds == null) return false;
      downloaded = await _fetchGraph(bounds);
    } on OsmRequestException {
      return false;
    }
    if (downloaded.nodes.isEmpty) return false;

    graph = downloaded;
    currentCity = cityName;
    try {
      await downloaded.saveGraph(filePath);
    } catch (_) {
      // Caching is best-effort; the graph is usable in memory regardless.
    }
    return true;
  }

  /// Leaves offline mode; subsequent [findTotalTrip] calls fetch live data.
  void useOnlineData() {
    currentCity = null;
  }
}
