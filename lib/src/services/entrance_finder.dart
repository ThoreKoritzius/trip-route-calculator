import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class BuildingAndEntranceFinder {
  final Distance distance = const Distance();
  final String overpassUrl = "http://overpass-api.de/api/interpreter";
  final double searchRadius = 50.0; // Radius in meters

  //search for buildings and entrances around the given input location
  String _generateOverpassQuery(
      List<LatLng> inputLocations, double radiusMeters) {
    final buffer = StringBuffer();
    buffer.writeln("[out:json];");
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

  Future<Map<String, dynamic>> _fetchCombinedData(
      List<LatLng> inputLocations) async {
    final query = _generateOverpassQuery(inputLocations, 50);

    final response = await http.post(
      Uri.parse("http://overpass-api.de/api/interpreter"),
      body: {"data": query},
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception("Failed to fetch data from Overpass API");
    }
  }

  Future<List<LatLng>> findBuildingAndEntrance(
      List<LatLng> inputLocations) async {
    List<LatLng> entranceLocations = [];

    try {
      final data = await _fetchCombinedData(inputLocations);

      // Extract entrances and buildings
      List<Map<String, dynamic>> entrances = [];
      Map<int, Map<String, dynamic>> buildings = {};

      for (var element in data['elements']) {
        if (element['type'] == 'way' &&
            element['tags'] != null &&
            element['tags']['building'] != null) {
          buildings[element['id']] = element;
        } else if (element['type'] == 'node' &&
            element['tags'] != null &&
            element['tags']['entrance'] != null) {
          entrances.add(element);
        }
      }

      // Process each input location
      for (final inputLocation in inputLocations) {
        // Step 1: Search for entrances in the radius
        final nearbyEntrances = entrances.where((entrance) {
          final entranceLat = entrance['lat'] as double;
          final entranceLon = entrance['lon'] as double;
          return distance.as(
                LengthUnit.Meter,
                inputLocation,
                LatLng(entranceLat, entranceLon),
              ) <=
              searchRadius;
        }).toList();
        if (nearbyEntrances.isNotEmpty) {
          // Step 2: Check if the input location is inside a building
          Map<String, dynamic>? containingBuilding;
          for (var building in buildings.values) {
            // Check if the input location is inside this polygon
            if (isPointInPolygon(inputLocation, building)) {
              containingBuilding = building;
              break;
            }
          }
          if (containingBuilding != null) {
            print("Found building: ${containingBuilding['id']}");

            // Step 3: Fetch entrances to the building
            final relevantEntrances = entrances.where((entrance) {
              final lat = entrance['lat'] as double;
              final lon = entrance['lon'] as double;
              return isPointInPolygon(LatLng(lat, lon), containingBuilding);
            }).toList();

            // Prefer 'entrance=main' if available
            final mainEntrance = relevantEntrances.firstWhere(
                (entrance) => entrance['tags']['entrance'] == 'main',
                orElse: () => <String, dynamic>{});

            if (mainEntrance.isNotEmpty) {
              entranceLocations.add(LatLng(mainEntrance['lat'] as double,
                  mainEntrance['lon'] as double));
            } else if (relevantEntrances.isNotEmpty) {
              entranceLocations.add(LatLng(
                  relevantEntrances.first['lat'] as double,
                  relevantEntrances.first['lon'] as double));
            } else {
              entranceLocations.add(inputLocation);
            }
          } else {
            entranceLocations.add(inputLocation);
          }
        } else {
          print("No nearby entrances found for ${inputLocation.toString()}");
          entranceLocations.add(inputLocation);
        }
      }
    } catch (e) {
      print("Error: $e");
      return inputLocations;
    }

    return entranceLocations;
  }

  // Point-in-polygon check
  bool isPointInPolygon(LatLng point, var buildingDict) {
    var bbox = buildingDict['bounds'];
    if (point.latitude < bbox['minlat'] ||
        point.latitude > bbox['maxlat'] ||
        point.longitude < bbox['minlon'] ||
        point.longitude > bbox['maxlon']) {
      return false;
    }

    final polygon = buildingDict['geometry'].map((node) {
      final lat = node['lat'] as double;
      final lon = node['lon'] as double;
      return LatLng(lat, lon);
    }).toList();

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
