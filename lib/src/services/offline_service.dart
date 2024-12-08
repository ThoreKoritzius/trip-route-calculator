import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

Future<String> downloadCity(String city) async {
  // Example: Temporary file path
  final storeFilePath = '$city.json';

  // Fetch city bounding box using an external API (e.g., OpenCage or Mapbox)
  final boundingBox = await _fetchBoundingBox(city);
  if (boundingBox == null) {
    print('Could not fetch bounding box for $city.');
    return '';
  }

  // Unpack bounding box values
  final minLat = boundingBox['minLat'];
  final minLon = boundingBox['minLon'];
  final maxLat = boundingBox['maxLat'];
  final maxLon = boundingBox['maxLon'];

  // Overpass query
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
      // Parse response data
      final rawData = jsonDecode(response.body) as Map<String, dynamic>;
      final data = rawData['elements'] as List;

      // Save data to file
      final file = File(storeFilePath);
      await file.writeAsString(jsonEncode(data));

      print('Data saved to $storeFilePath');
      return storeFilePath;
    } else {
      print('Error: ${response.statusCode} ${response.reasonPhrase}');
      return '';
    }
  } catch (e) {
    print('Exception occurred: $e');
    return '';
  }
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
