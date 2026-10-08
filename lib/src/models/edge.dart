class Edge {
  final int from;
  final int to;
  final double weight;

  /// Whether this edge belongs to a dedicated walking way
  /// (e.g. `highway=footway|pedestrian|path|steps`).
  final bool isFootWay;

  Edge(this.from, this.to, this.weight, {this.isFootWay = false});

  @override
  String toString() {
    return 'from: $from, to: $to, weight: $weight, isFootWay: $isFootWay';
  }
}
