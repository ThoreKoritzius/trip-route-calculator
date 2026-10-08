import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:trip_routing/trip_routing.dart';

Map<String, dynamic> osmNode(int id, double lat, double lon) =>
    {'type': 'node', 'id': id, 'lat': lat, 'lon': lon};

Map<String, dynamic> osmWay(int id, List<int> nodes, String highway) => {
      'type': 'way',
      'id': id,
      'nodes': nodes,
      'tags': {'highway': highway},
    };

/// 1 --road-- 2 --road-- 3 -- 5 ~(5 cm)~ 6 -- 7
///  \______footway 4______/
/// plus a disconnected island 10 -- 11.
final fixture = <Map<String, dynamic>>[
  osmNode(1, 50.0, 6.000),
  osmNode(2, 50.0, 6.001),
  osmNode(3, 50.0, 6.002),
  osmNode(4, 50.0002, 6.001),
  osmNode(5, 50.0, 6.003),
  osmNode(6, 50.0000005, 6.003),
  osmNode(7, 50.0, 6.004),
  osmNode(10, 50.01, 6.01),
  osmNode(11, 50.01, 6.011),
  osmWay(100, [1, 2, 3], 'primary'),
  osmWay(101, [1, 4, 3], 'footway'),
  osmWay(102, [3, 5, 6, 7], 'residential'),
  osmWay(103, [10, 11], 'residential'),
];

LatLng pos(Graph g, int id) => LatLng(g.nodes[id]!.lat, g.nodes[id]!.lon);

int edgeCount(Graph g) =>
    g.adjacencyList.values.fold(0, (sum, edges) => sum + edges.length);

http.Client overpassMock({List<String>? userAgents}) => MockClient((request) {
      userAgents?.add(request.headers['User-Agent'] ?? '');
      if (request.url.host == 'overpass-api.de') {
        return Future.value(
            http.Response(jsonEncode({'elements': fixture}), 200));
      }
      if (request.url.host == 'nominatim.openstreetmap.org') {
        return Future.value(http.Response(
            jsonEncode([
              {
                'boundingbox': ['49.99', '50.02', '5.99', '6.02']
              }
            ]),
            200));
      }
      return Future.value(http.Response('not found', 404));
    });
