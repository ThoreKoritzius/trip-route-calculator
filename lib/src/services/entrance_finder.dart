import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'osm_client.dart';

class BuildingAndEntranceFinder {
  final Distance distance = const Distance();
  final double searchRadius = 50.0; // Radius in meters
  final OsmClient _osm;

  BuildingAndEntranceFinder({OsmClient? osmClient})
      : _osm = osmClient ?? OsmClient();

  //search for buildings and entrances around the given input location
  String _generateOverpassQuery(
      List<LatLng> inputLocations, double radiusMeters) {
    final buffer = StringBuffer();
    buffer.writeln("[out:json][timeout:${_osm.timeout.inSeconds}];");
    buffer.writeln("(");
    for (final location in inputLocations) {
      buffer.writeln(
          '  node["entrance"](around:$radiusMeters, ${location.latitude}, ${location.longitude});');
      buffer.writeln(
          '  way["building"](around:$radiusMeters, ${location.latitude}, ${location.longitude});');
    }
    buffer.writeln(");");
    buffer.writeln("out body geom;");
    return buffer.toString();
  }

  /// Returns, for every input location, the main (or first) entrance of the
  /// building it lies in, or the input location itself if none is found.
  Future<List<LatLng>> findBuildingAndEntrance(
      List<LatLng> inputLocations) async {
    if (inputLocations.isEmpty) return [];
    List<LatLng> entranceLocations = [];

    try {
      final elements = await _osm
          .overpass(_generateOverpassQuery(inputLocations, searchRadius));

      // Extract entrances and buildings
      List<Map<String, dynamic>> entrances = [];
      List<Map<String, dynamic>> buildings = [];

      for (var element in elements) {
        if (element is! Map<String, dynamic>) continue;
        final tags = element['tags'];
        if (tags is! Map) continue;
        if (element['type'] == 'way' &&
            tags['building'] != null &&
            element['geometry'] is List) {
          buildings.add(element);
        } else if (element['type'] == 'node' &&
            tags['entrance'] != null &&
            element['lat'] is num &&
            element['lon'] is num) {
          entrances.add(element);
        }
      }

      for (final inputLocation in inputLocations) {
        entranceLocations.add(
            _entranceFor(inputLocation, entrances, buildings) ?? inputLocation);
      }
    } catch (e) {
      return inputLocations;
    }

    return entranceLocations;
  }

  LatLng? _entranceFor(LatLng location, List<Map<String, dynamic>> entrances,
      List<Map<String, dynamic>> buildings) {
    // Step 1: Is the input location inside a building?
    final building =
        buildings.where((b) => isPointInPolygon(location, b)).firstOrNull;
    if (building == null) return null;

    // Step 2: Entrances are vertices of the building outline, so match them
    // by node id (a point-in-polygon test on the boundary is unreliable).
    final buildingNodeIds = (building['nodes'] as List?)?.toSet() ?? {};
    final relevantEntrances = entrances.where((entrance) {
      if (buildingNodeIds.contains(entrance['id'])) return true;
      return distance.as(LengthUnit.Meter, location, _latLng(entrance)) <=
              searchRadius &&
          isPointInPolygon(_latLng(entrance), building);
    }).toList();
    if (relevantEntrances.isEmpty) return null;

    // Prefer 'entrance=main' if available
    final main = relevantEntrances
        .where((e) => e['tags']['entrance'] == 'main')
        .firstOrNull;
    return _latLng(main ?? relevantEntrances.first);
  }

  LatLng _latLng(Map<String, dynamic> element) => LatLng(
      (element['lat'] as num).toDouble(), (element['lon'] as num).toDouble());

  // Point-in-polygon check
  bool isPointInPolygon(LatLng point, var buildingDict) {
    var bbox = buildingDict['bounds'];
    if (bbox != null &&
        (point.latitude < bbox['minlat'] ||
            point.latitude > bbox['maxlat'] ||
            point.longitude < bbox['minlon'] ||
            point.longitude > bbox['maxlon'])) {
      return false;
    }

    final polygon = (buildingDict['geometry'] as List)
        .whereType<Map>()
        .map((node) => LatLng(
            (node['lat'] as num).toDouble(), (node['lon'] as num).toDouble()))
        .toList();
    if (polygon.length < 3) return false;

    // Ray-casting algorithm
    int intersections = 0;
    for (int i = 0; i < polygon.length; i++) {
      final p1 = polygon[i];
      final p2 = polygon[(i + 1) % polygon.length];

      if (rayIntersectsSegment(point, p1, p2)) {
        intersections++;
      }
    }
    return intersections % 2 == 1;
  }

  bool rayIntersectsSegment(LatLng point, LatLng p1, LatLng p2) {
    if (p1.latitude > p2.latitude) {
      final temp = p1;
      p1 = p2;
      p2 = temp;
    }
    if (point.latitude == p1.latitude || point.latitude == p2.latitude) {
      point = LatLng(point.latitude + 1e-10, point.longitude);
    }
    if (point.latitude < p1.latitude ||
        point.latitude > p2.latitude ||
        point.longitude >= max(p1.longitude, p2.longitude)) {
      return false;
    }
    if (point.longitude < min(p1.longitude, p2.longitude)) {
      return true;
    }
    final redge = (point.latitude - p1.latitude) /
            (p2.latitude - p1.latitude) *
            (p2.longitude - p1.longitude) +
        p1.longitude;
    return point.longitude < redge;
  }
}
