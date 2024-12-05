import 'dart:math';

import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class BuildingAndEntranceFinder {
  final Distance distance = Distance();

  final String overpassUrl = "http://overpass-api.de/api/interpreter";

  Future<Map<String, dynamic>> fetchBuildingAndEntrances(
      double latitude, double longitude, double searchRadius) async {
    final query = '''
    [out:json];
    (
      way["building"](around:$searchRadius,$latitude,$longitude);
      node["entrance"](around:$searchRadius,$latitude,$longitude);
    );
    out body geom;
    ''';

    final response = await http.post(
      Uri.parse(overpassUrl),
      body: {"data": query},
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception("Failed to fetch data from Overpass API");
    }
  }

  Future<LatLng> findBuildingAndEntrance(LatLng inputLocation) async {
    const double searchRadius = 50.0;

    try {
      final data = await fetchBuildingAndEntrances(
          inputLocation.latitude, inputLocation.longitude, searchRadius);

      // Extract buildings and entrances from the response
      List<Map<String, dynamic>> buildings = [];
      List<Map<String, dynamic>> entrances = [];

      for (var element in data['elements']) {
        if (element['type'] == 'way' &&
            element['tags'] != null &&
            element['tags']['building'] != null) {
          buildings.add(element);
        } else if (element['type'] == 'node' &&
            element['tags'] != null &&
            element['tags']['entrance'] != null) {
          entrances.add(element);
        }
      }

      // Find the building containing the marker
      Map<String, dynamic>? containingBuilding;

      for (var building in buildings) {
        final geometry = building['geometry'];

        List<LatLng> polygon = geometry.map<LatLng>((node) {
          return LatLng(node['lat'], node['lon']);
        }).toList();
        if (isPointInPolygon(inputLocation, polygon)) {
          containingBuilding = building;
          break;
        }
      }

      if (containingBuilding != null) {
        print("Found building: ${containingBuilding['id']}");

        // Filter entrances within the building polygon
        final buildingPolygon = containingBuilding['geometry']
            .map((node) => LatLng(node['lat'], node['lon']))
            .toList();
        final relevantEntrances = entrances
            .where((entrance) => isPointInPolygon(
                LatLng(entrance['lat'], entrance['lon']),
                List.from(buildingPolygon)))
            .toList();

        // Prefer 'entrance=main'
        final mainEntrance = relevantEntrances.firstWhere(
            (entrance) => entrance['tags']['entrance'] == 'main',
            orElse: () => <String, dynamic>{});

        if (mainEntrance.isNotEmpty) {
          print(
              "Main entrance: ${mainEntrance['id']} at ${mainEntrance['lat']}, ${mainEntrance['lon']}");
          return LatLng(
              mainEntrance['lat'] as double, mainEntrance['lon'] as double);
        } else if (relevantEntrances.isNotEmpty) {
          print(
              "Other entrances found: ${relevantEntrances.map((e) => e['id']).join(', ')}");
          return LatLng(relevantEntrances.first['lat'] as double,
              relevantEntrances.first['lon'] as double);
        } else {
          print("No entrances found for this building.");
          return inputLocation;
        }
      } else {
        print("No building found at the given location.");
        return inputLocation;
      }
    } catch (e) {
      print("Error: $e");
      return inputLocation;
    }
  }

  // Point-in-polygon check
  bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
    int intersections = 0;
    for (int i = 0; i < polygon.length; i++) {
      final p1 = polygon[i];
      final p2 = polygon[(i + 1) % polygon.length];

      if (rayIntersectsSegment(point, p1, p2)) {
        intersections++;
      }
    }
    return intersections % 2 == 1; // Odd number of intersections = inside
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
