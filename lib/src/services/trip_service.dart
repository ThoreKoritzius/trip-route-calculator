import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';

/// TripService provides routing and trip planning over OSM and cached city graphs.
///
/// Main entrypoint: [findTotalTrip].
class TripService {
  /// Default cost multiplier for edges on dedicated walking ways when
  /// `preferWalkingPaths` is enabled (a footway may be ~11% longer).
  static const double defaultFootwayCostFactor = 0.9;

  /// Default maximum distance (meters) between a waypoint and the walkable
  /// network; waypoints further away are reported as errors.
  static const double defaultMaxSnapDistance = 1000;

  /// Minimum padding (in degrees, ~500 m) around the waypoints when fetching
  /// online data, so nearby or collinear waypoints still get a usable area.
  static const double minBoundsPaddingDegrees = 0.005;

  final OsmClient _osm;
  final BuildingAndEntranceFinder entranceFinder;

  /// If not null, current offline city name.
  String? currentCity;

  /// Why the last [useCity] call could not download the city data, e.g.
  /// `Overpass request failed with HTTP 504 (server busy)`. Also set when a
  /// refresh failed and a stale cache was used instead; `null` otherwise.
  String? lastCityError;

  /// The graph used for routing. Set by [useCity] for offline routing and
  /// updated with the fetched data on every online [findTotalTrip] call.
  Graph graph = Graph();

  /// How long the graph fetched for an online request is reused for later
  /// requests whose area lies within it. [Duration.zero] disables reuse.
  final Duration onlineCacheDuration;
  _OnlineArea? _onlineArea;

  /// [httpClient] can be supplied to customise networking (e.g. for tests).
  TripService({
    http.Client? httpClient,
    OsmClient? osmClient,
    Duration onlineCacheDuration = const Duration(minutes: 10),
  }) : this._(osmClient ?? OsmClient(client: httpClient), onlineCacheDuration);

  TripService._(this._osm, this.onlineCacheDuration)
      : entranceFinder = BuildingAndEntranceFinder(osmClient: _osm);

  /// Compute the shortest path between two graph nodes, optionally preferring
  /// walking paths.
  ///
  /// Returns a [Trip] with empty route and `distance = 0.0` if route cannot be found.
  Trip shortestPath(Graph graph, int startId, int targetId,
      {bool preferWalkingPaths = true}) {
    final start = graph.nodes[startId];
    final target = graph.nodes[targetId];
    if (start == null || target == null) {
      return Trip(
          route: [], distance: 0.0, errors: ['Start/target node not found.']);
    }
    final result = routeBetween(
        graph,
        GraphSnap.atNode(start),
        GraphSnap.atNode(target),
        RouteCosts(preferWalkingPaths: preferWalkingPaths));
    if (result == null) {
      return Trip(route: [], distance: 0.0, errors: ['No path found.']);
    }
    return Trip(route: result.route, distance: result.distance, errors: []);
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
  ///   - [footwayCostFactor]: cost multiplier for walking ways when
  ///     [preferWalkingPaths] is set; lower values prefer them more strongly.
  ///   - [avoidSteps]: makes stairs 5x as expensive, e.g. for wheelchairs.
  ///   - [maxSnapDistance]: waypoints further than this (meters) from any
  ///     walkable way are reported in `errors` and their legs are skipped.
  ///
  /// Waypoints are snapped to the closest point on the walkable network, so
  /// routes start and end on the road next to them rather than at the
  /// nearest intersection or way node.
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
    double footwayCostFactor = defaultFootwayCostFactor,
    bool avoidSteps = false,
    double maxSnapDistance = defaultMaxSnapDistance,
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

    // Entrance lookup and graph download run in parallel. Entrances lie
    // within 50 m of the waypoints, well inside the minimum bounds padding.
    // Entrances are also looked up in offline mode; without connectivity the
    // original waypoints are kept.
    final entrancesFuture = replaceWaypointsWithBuildingEntrances
        ? entranceFinder.findBuildingAndEntrance(waypoints)
        : null;

    // ONLINE mode: build the graph from the waypoints' bounding box
    if (currentCity == null) {
      bounds = findLatLonBounds(waypoints,
          minPaddingDegrees: minBoundsPaddingDegrees);
      try {
        (routingGraph, bounds) = await _onlineGraph(bounds);
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

    if (entrancesFuture != null) {
      final entrances = await entrancesFuture;
      if (entrances.length == waypoints.length) {
        foundEntrance = [
          for (var i = 0; i < waypoints.length; i++)
            entrances[i] != waypoints[i]
        ];
        waypoints = entrances;
      }
    }

    if (routingGraph.nodes.isEmpty) {
      return Trip(
          route: [],
          distance: 0.0,
          errors: ['Graph data unavailable'],
          boundingBox: bounds);
    }

    final costs = RouteCosts(
      preferWalkingPaths: preferWalkingPaths,
      footwayCostFactor: footwayCostFactor,
      avoidSteps: avoidSteps,
      duplicationPenalty: duplicationPenalty,
    );
    final errors = <String>[];
    final snaps = <GraphSnap?>[];
    for (var i = 0; i < waypoints.length; i++) {
      final snap = snapToGraph(routingGraph, waypoints[i]);
      if (snap == null || snap.distance > maxSnapDistance) {
        errors.add('Waypoint ${i + 1} is ${snap?.distance.round() ?? '?'} m '
            'from the nearest walkable way (max ${maxSnapDistance.round()} m).');
        snaps.add(null);
      } else {
        snaps.add(snap);
      }
    }

    final totalRoute = <LatLng>[];
    var totalDistance = 0.0;
    final usedEdges = <(int, int)>{};
    bool include(int i) => forceIncludeWaypoints || foundEntrance[i];
    void append(LatLng point) {
      if (totalRoute.isEmpty || totalRoute.last != point) totalRoute.add(point);
    }

    for (var i = 0; i < waypoints.length - 1; i++) {
      final from = snaps[i];
      final to = snaps[i + 1];
      if (from == null || to == null) continue;

      final leg =
          routeBetween(routingGraph, from, to, costs, usedEdges: usedEdges);
      if (leg == null) {
        errors.add('Leg ${i + 1}: No path found.');
        continue;
      }

      // Off-network connectors to included waypoints count towards distance.
      if (include(i)) {
        append(waypoints[i]);
        totalDistance += _distance(waypoints[i], from.point);
      }
      leg.route.forEach(append);
      totalDistance += leg.distance;
      if (include(i + 1)) {
        append(waypoints[i + 1]);
        totalDistance += _distance(to.point, waypoints[i + 1]);
      }
    }

    return Trip(
        route: totalRoute,
        distance: totalDistance,
        errors: errors,
        boundingBox: bounds);
  }

  double _distance(LatLng a, LatLng b) =>
      haversineDistance(a.latitude, a.longitude, b.latitude, b.longitude);

  /// The graph for [bounds], reusing the previous online graph if it covers
  /// them and is recent enough. Returns the graph and the bounds it covers.
  Future<(Graph, List<double>)> _onlineGraph(List<double> bounds) async {
    final area = _onlineArea;
    if (area != null &&
        area.covers(bounds) &&
        DateTime.now().difference(area.fetchedAt) < onlineCacheDuration) {
      return (area.graph, area.bounds);
    }
    final fetched = await _fetchGraph(bounds);
    if (onlineCacheDuration > Duration.zero && fetched.nodes.isNotEmpty) {
      _onlineArea = _OnlineArea(bounds, fetched, DateTime.now());
    }
    return (fetched, bounds);
  }

  /// Fetch and parse the OSM graph in a bounding box.
  Future<Graph> _fetchGraph(List<double> bounds) async {
    final elements = await _osm.fetchWalkableWays(
        bounds[0], bounds[1], bounds[2], bounds[3]);
    return buildGraphFromOsmElements(elements)
      ..createdAt = DateTime.now().toUtc();
  }

  /// Get the data path for this city name. (Override for specific platforms.)
  ///
  /// Caches are stored in a compact binary format. Caches written by
  /// versions up to 0.0.13 (`<city>.json`) are still read and migrated.
  Future<String> getCityPath(String cityName) async => '$cityName.trg';

  /// Downloads routing data for a specified city and uses the cached file for future routing.
  ///
  /// Parameters:
  /// - [cityName]: The name of the city for which routing data is being prepared.
  /// - [maxAge]: if set, a cached file older than this (or without a download
  ///   timestamp) is refreshed. If the refresh fails, the stale cache is used.
  ///
  /// On platforms without a file system (web) the data is kept in memory only.
  /// Building entrances (`replaceWaypointsWithBuildingEntrances`) are still
  /// looked up online in offline mode, falling back to the original waypoints.
  ///
  /// Returns:
  /// - A `Future<bool>` indicating whether the operation was successful:
  ///   - `true`: Routing data was successfully loaded or downloaded.
  ///   - `false`: The city could not be found or its data could not be fetched.
  ///     The service then stays in its previous mode.
  Future<bool> useCity(String cityName, {Duration? maxAge}) async {
    lastCityError = null;
    final filePath = await getCityPath(cityName);
    var cached = await _loadCache(filePath);
    if (cached == null && filePath.endsWith('.trg')) {
      // Migrate a JSON cache written by 0.0.13 or earlier (`<city>.json`).
      final legacyPath = '${filePath.substring(0, filePath.length - 4)}.json';
      cached = await _loadCache(legacyPath);
      if (cached != null) await _saveCache(cached, filePath);
    }

    final createdAt = cached?.createdAt;
    final isFresh = maxAge == null ||
        (createdAt != null &&
            DateTime.now().toUtc().difference(createdAt) <= maxAge);
    if (cached != null && isFresh) return _activate(cityName, cached);

    Graph? downloaded;
    try {
      final bounds = await _osm.fetchCityBounds(cityName);
      if (bounds == null) {
        lastCityError = 'City "$cityName" not found.';
      } else {
        downloaded = await _fetchGraph(bounds);
        if (downloaded.nodes.isEmpty) {
          lastCityError = 'No walkable ways found for "$cityName".';
        }
      }
    } on OsmRequestException catch (e) {
      // Fall back to a stale cache below, if there is one.
      lastCityError = e.message;
    }
    if (downloaded == null || downloaded.nodes.isEmpty) {
      return cached != null && _activate(cityName, cached);
    }

    await _saveCache(downloaded, filePath);
    return _activate(cityName, downloaded);
  }

  Future<Graph?> _loadCache(String filePath) async {
    try {
      final cached = await Graph.fromFile(filePath);
      return cached.nodes.isEmpty ? null : cached;
    } catch (_) {
      return null; // Missing, unreadable, or no file system (web).
    }
  }

  Future<void> _saveCache(Graph cityGraph, String filePath) async {
    try {
      await cityGraph.saveGraph(filePath);
    } catch (_) {
      // Caching is best-effort; the graph is usable in memory regardless.
    }
  }

  bool _activate(String cityName, Graph cityGraph) {
    graph = cityGraph;
    currentCity = cityName;
    return true;
  }

  /// Leaves offline mode; subsequent [findTotalTrip] calls fetch live data.
  void useOnlineData() {
    currentCity = null;
  }
}

/// The most recently fetched online graph and the area it covers.
class _OnlineArea {
  final List<double> bounds;
  final Graph graph;
  final DateTime fetchedAt;

  _OnlineArea(this.bounds, this.graph, this.fetchedAt);

  bool covers(List<double> other) =>
      other[0] >= bounds[0] &&
      other[1] >= bounds[1] &&
      other[2] <= bounds[2] &&
      other[3] <= bounds[3];
}
