import 'package:latlong2/latlong.dart';

class Trip {
  final List<LatLng> route;
  final double distance;
  final List<String> errors;
  Trip({required this.route, required this.distance, required this.errors});
}
