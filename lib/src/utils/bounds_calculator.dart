import 'package:latlong2/latlong.dart';

List<double> findLatLonBounds(List<LatLng> points,
      {double paddingLat = 0.3, double paddingLon = 0.1}) {
    if (points.isEmpty) {
      throw ArgumentError('The list of attractions cannot be empty.');
    }

    // Initialize min and max values to the first position
    var minLat = points[0].latitude;
    var maxLat = points[0].latitude;
    var minLon = points[0].longitude;
    var maxLon = points[0].longitude;

    // Iterate through the attractions list to find min/max values
    for (final point in points) {
      final lat = point.latitude;
      final lon = point.longitude;

      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
    }

    final latPadding = (maxLat - minLat) * paddingLat;
    final lonPadding = (maxLon - minLon) * paddingLon;

    minLat -= latPadding;
    maxLat += latPadding;
    minLon -= lonPadding;
    maxLon += lonPadding;

    return [minLat, minLon, maxLat, maxLon];
  }