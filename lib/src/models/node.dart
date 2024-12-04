class Node {
  final int id;
  final double lat;
  final double lon;
  bool isFootWay;

  set setIsFootWay(bool value) {
    isFootWay = value;
  }

  Node(this.id, this.lat, this.lon, this.isFootWay);

  @override
  String toString() {
    return '{"lat": $lat, "lon": $lon}, ';
  }
}
