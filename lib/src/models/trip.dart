import 'package:latlong2/latlong.dart';

class Trip {
  final List<LatLng> route;
  final double distance;

  Trip({required this.route, required this.distance});
}
