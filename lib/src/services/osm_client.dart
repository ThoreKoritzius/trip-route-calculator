import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

/// Thrown when an OSM web service (Overpass/Nominatim) request fails.
class OsmRequestException implements Exception {
  final String message;

  /// Whether retrying the same request later may succeed (server busy,
  /// timeouts, connection problems).
  final bool isTransient;

  OsmRequestException(this.message, {this.isTransient = false});

  @override
  String toString() => 'OsmRequestException: $message';
}

/// Thin wrapper around the public Overpass and Nominatim APIs.
class OsmClient {
  static const defaultOverpassUrl = 'https://overpass-api.de/api/interpreter';
  static const defaultNominatimUrl = 'https://nominatim.openstreetmap.org';

  /// overpass-api.de rejects the default `Dart/x.y (dart:io)` agent with
  /// HTTP 406 and Nominatim's usage policy requires an identifying agent.
  static const defaultUserAgent =
      'trip_routing (+https://github.com/ThoreKoritzius/trip-route-calculator)';

  /// Highway types that are never walkable.
  static const _excludedHighways =
      'motorway|motorway_link|construction|proposed|raceway|bus_guideway|abandoned';

  static const _transientStatusCodes = {429, 500, 502, 503, 504};

  final http.Client _client;
  final String overpassUrl;

  /// Additional Overpass instances tried (in order) when [overpassUrl] keeps
  /// failing with transient errors. Empty by default so that coordinates are
  /// only sent to third-party mirrors when explicitly configured.
  final List<String> fallbackOverpassUrls;
  final String nominatimUrl;
  final String userAgent;
  final Duration timeout;

  /// How often a request failing with a transient error is retried.
  final int maxRetries;

  /// Delay before the first retry; doubled for each further retry. A
  /// `Retry-After` header from the server takes precedence (capped at 30 s).
  final Duration retryDelay;

  OsmClient({
    http.Client? client,
    this.overpassUrl = defaultOverpassUrl,
    this.fallbackOverpassUrls = const [],
    this.nominatimUrl = defaultNominatimUrl,
    this.userAgent = defaultUserAgent,
    this.timeout = const Duration(seconds: 90),
    this.maxRetries = 2,
    this.retryDelay = const Duration(seconds: 2),
  }) : _client = client ?? http.Client();

  /// Runs an Overpass QL [query] and returns its `elements`.
  ///
  /// [maxRetries] overrides [OsmClient.maxRetries] for this request.
  Future<List<dynamic>> overpass(String query, {int? maxRetries}) {
    final endpoints = [overpassUrl, ...fallbackOverpassUrls];
    return _withRetries(maxRetries ?? this.maxRetries, (attempt) async {
      // Spread retries over the configured endpoints, primary first.
      final url = endpoints[min(attempt, endpoints.length - 1)];
      final response = await _send(
          'Overpass',
          () => _client
              .post(Uri.parse(url), headers: _headers, body: {'data': query}));
      final decoded = _decodeJson(response.body, 'Overpass');
      // Overpass reports query timeouts/out-of-memory as HTTP 200 with a
      // `remark` and truncated elements; treat that as a (retryable) failure.
      final remark = decoded is Map ? decoded['remark'] : null;
      if (remark is String && remark.contains('error')) {
        throw OsmRequestException('Overpass query failed: $remark',
            isTransient: true);
      }
      final elements = decoded is Map ? decoded['elements'] : null;
      if (elements is! List) {
        throw OsmRequestException('Overpass response contained no elements');
      }
      return elements;
    });
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
    final results = await _withRetries(maxRetries, (_) async {
      final response =
          await _send('Nominatim', () => _client.get(uri, headers: _headers));
      return _decodeJson(response.body, 'Nominatim');
    });
    if (results is! List || results.isEmpty) return null;
    final bbox = results.first['boundingbox'];
    if (bbox is! List || bbox.length < 4) return null;
    final values = bbox.map((v) => double.tryParse('$v')).toList();
    if (values.any((v) => v == null || !v.isFinite)) return null;
    // Nominatim order: [minLat, maxLat, minLon, maxLon]
    return [values[0]!, values[2]!, values[1]!, values[3]!];
  }

  Map<String, String> get _headers => {'User-Agent': userAgent};

  Future<T> _withRetries<T>(
      int maxRetries, Future<T> Function(int attempt) run) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await run(attempt);
      } on _RetryAfter catch (e) {
        if (attempt >= maxRetries) throw e.cause;
        await Future<void>.delayed(e.delay ?? _backoff(attempt));
      } on OsmRequestException catch (e) {
        if (!e.isTransient || attempt >= maxRetries) rethrow;
        await Future<void>.delayed(_backoff(attempt));
      }
    }
  }

  Duration _backoff(int attempt) => retryDelay * pow(2, attempt).toInt();

  Future<http.Response> _send(
      String service, Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw OsmRequestException('$service request timed out',
          isTransient: true);
    } catch (e) {
      throw OsmRequestException('$service request failed: $e',
          isTransient: true);
    }
    if (response.statusCode == 200) return response;

    final busy = response.statusCode == 429 || response.statusCode == 504
        ? ' (server busy)'
        : '';
    final error = OsmRequestException(
        '$service request failed with HTTP ${response.statusCode}$busy',
        isTransient: _transientStatusCodes.contains(response.statusCode));
    if (!error.isTransient) throw error;
    final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    throw _RetryAfter(error,
        retryAfter == null ? null : Duration(seconds: min(retryAfter, 30)));
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

/// Internal signal carrying a transient HTTP error and optional server delay.
class _RetryAfter implements Exception {
  final OsmRequestException cause;
  final Duration? delay;
  _RetryAfter(this.cause, this.delay);
}
