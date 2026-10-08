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

/// Returns `[minLat, minLon, maxLat, maxLon]` derived only from which cells
/// of a fixed global grid the [points] lie in.
///
/// Cells are [cellLatDegrees] x ([cellLatDegrees] * 1.5), about 1.1 x 1.1 km
/// at 50° N for the default. The box spanning the points' cells is padded
/// like [findLatLonBounds] (30% of its size, at least [minPaddingDegrees]).
/// Because nothing depends on the exact coordinates, any points within the
/// same cells produce exactly the same bounds, so requesting map data for
/// them reveals the points no more precisely than their cells.
List<double> findGridBounds(List<LatLng> points,
    {double cellLatDegrees = 0.01, double minPaddingDegrees = 0.005}) {
  if (points.isEmpty) {
    throw ArgumentError('The list of points cannot be empty.');
  }
  final cellLon = cellLatDegrees * 1.5;
  final ys = points.map((p) => (p.latitude / cellLatDegrees).floor());
  final xs = points.map((p) => (p.longitude / cellLon).floor());
  final minY = ys.reduce(min), maxY = ys.reduce(max) + 1;
  final minX = xs.reduce(min), maxX = xs.reduce(max) + 1;
  final padY = max((maxY - minY) * cellLatDegrees * 0.3, minPaddingDegrees);
  final padX = max((maxX - minX) * cellLon * 0.3, minPaddingDegrees);
  // Rounded so that equal cells always print identically in queries.
  double round(double v) => double.parse(v.toStringAsFixed(6));
  return [
    max(round(minY * cellLatDegrees - padY), -90.0),
    max(round(minX * cellLon - padX), -180.0),
    min(round(maxY * cellLatDegrees + padY), 90.0),
    min(round(maxX * cellLon + padX), 180.0),
  ];
}
