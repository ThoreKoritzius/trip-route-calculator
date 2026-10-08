import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thrown when an OSM web service (Overpass/Nominatim) request fails.
class OsmRequestException implements Exception {
  final String message;
  OsmRequestException(this.message);

  @override
  String toString() => 'OsmRequestException: $message';
}

/// Thin wrapper around the public Overpass and Nominatim APIs.
class OsmClient {
  static const defaultOverpassUrl = 'https://overpass-api.de/api/interpreter';
  static const defaultNominatimUrl = 'https://nominatim.openstreetmap.org';

  /// Nominatim's usage policy requires an identifying User-Agent; requests
  /// with the default `Dart/x.y (dart:io)` agent are frequently rejected.
  static const defaultUserAgent =
      'trip_routing (+https://github.com/ThoreKoritzius/trip-route-calculator)';

  /// Highway types that are never walkable.
  static const _excludedHighways =
      'motorway|motorway_link|construction|proposed|raceway|bus_guideway|abandoned';

  final http.Client _client;
  final String overpassUrl;
  final String nominatimUrl;
  final String userAgent;
  final Duration timeout;

  OsmClient({
    http.Client? client,
    this.overpassUrl = defaultOverpassUrl,
    this.nominatimUrl = defaultNominatimUrl,
    this.userAgent = defaultUserAgent,
    this.timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client();

  /// Runs an Overpass QL [query] and returns its `elements`.
  Future<List<dynamic>> overpass(String query) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse(overpassUrl),
        headers: {'User-Agent': userAgent},
        body: {'data': query},
      ).timeout(timeout);
    } on TimeoutException {
      throw OsmRequestException('Overpass request timed out');
    } catch (e) {
      throw OsmRequestException('Overpass request failed: $e');
    }
    if (response.statusCode != 200) {
      throw OsmRequestException(
          'Overpass request failed with HTTP ${response.statusCode}');
    }
    final decoded = _decodeJson(response.body, 'Overpass');
    // Overpass reports query timeouts/out-of-memory as HTTP 200 with a
    // `remark` and truncated elements; treat that as a failure.
    final remark = decoded is Map ? decoded['remark'] : null;
    if (remark is String && remark.contains('error')) {
      throw OsmRequestException('Overpass query failed: $remark');
    }
    final elements = decoded is Map ? decoded['elements'] : null;
    if (elements is! List) {
      throw OsmRequestException('Overpass response contained no elements');
    }
    return elements;
  }

  /// Fetches all walkable highway ways (and their nodes) inside the bounds.
  Future<List<dynamic>> fetchWalkableWays(
      double minLat, double minLon, double maxLat, double maxLon) {
    final timeoutSeconds = timeout.inSeconds;
    return overpass('''
[out:json][timeout:$timeoutSeconds];
(
  way["highway"]["highway"!~"^($_excludedHighways)\$"]["area"!~"yes"]["place"!~"square"]["foot"!~"^(no|private)\$"]($minLat,$minLon,$maxLat,$maxLon);
);
out body;
>;
out skel qt;
''');
  }

  /// Looks up the bounding box of [city] via Nominatim.
  ///
  /// Returns `[minLat, minLon, maxLat, maxLon]`, or `null` if not found.
  Future<List<double>?> fetchCityBounds(String city) async {
    final uri = Uri.parse('$nominatimUrl/search').replace(queryParameters: {
      'city': city,
      'format': 'json',
      'limit': '1',
    });
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': userAgent}).timeout(timeout);
    } catch (e) {
      throw OsmRequestException('Nominatim request failed: $e');
    }
    if (response.statusCode != 200) {
      throw OsmRequestException(
          'Nominatim request failed with HTTP ${response.statusCode}');
    }
    final results = _decodeJson(response.body, 'Nominatim');
    if (results is! List || results.isEmpty) return null;
    final bbox = results.first['boundingbox'];
    if (bbox is! List || bbox.length < 4) return null;
    final values = bbox.map((v) => double.tryParse('$v')).toList();
    if (values.any((v) => v == null || !v.isFinite)) return null;
    // Nominatim order: [minLat, maxLat, minLon, maxLon]
    return [values[0]!, values[2]!, values[1]!, values[3]!];
  }

  dynamic _decodeJson(String body, String service) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw OsmRequestException(
          '$service returned an invalid (non-JSON) response');
    }
  }

  void close() => _client.close();
}
