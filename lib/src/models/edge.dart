class Edge {
  final int from;
  final int to;
  final double weight;

  /// Whether this edge belongs to a dedicated walking way
  /// (e.g. `highway=footway|pedestrian|path|steps`).
  final bool isFootWay;

  /// Whether this edge is part of a staircase (`highway=steps`).
  final bool isSteps;

  Edge(this.from, this.to, this.weight,
      {this.isFootWay = false, this.isSteps = false});

  /// The same edge in the opposite direction.
  Edge get reversed =>
      Edge(to, from, weight, isFootWay: isFootWay, isSteps: isSteps);

  @override
  String toString() {
    return 'from: $from, to: $to, weight: $weight, isFootWay: $isFootWay, isSteps: $isSteps';
  }
}
