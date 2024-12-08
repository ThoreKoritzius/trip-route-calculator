import 'package:latlong2/latlong.dart';

class Trip {
  final List<LatLng> route;
  final double distance;
  final List<String> errors;
  final List<double>? boundingBox;
  Trip(
      {required this.route,
      required this.distance,
      required this.errors,
      this.boundingBox});
}
