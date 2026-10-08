import 'dart:math';

import 'package:latlong2/latlong.dart';

/// Returns `[minLat, minLon, maxLat, maxLon]` around [points].
///
/// Each side is padded by the relative [paddingLat]/[paddingLon] fraction of
/// the box size, but by at least [minPaddingDegrees], so that a single point
/// or points on one line of latitude/longitude still yield a usable area.
List<double> findLatLonBounds(List<LatLng> points,
    {double paddingLat = 0.3,
    double paddingLon = 0.3,
    double minPaddingDegrees = 0.0}) {
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

  final latPadding = max((maxLat - minLat) * paddingLat, minPaddingDegrees);
  final lonPadding = max((maxLon - minLon) * paddingLon, minPaddingDegrees);

  minLat -= latPadding;
  maxLat += latPadding;
  minLon -= lonPadding;
  maxLon += lonPadding;

  return [
    max(minLat, -90.0),
    max(minLon, -180.0),
    min(maxLat, 90.0),
    min(maxLon, 180.0),
  ];
}
