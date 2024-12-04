class Edge {
  final int from;
  final int to;
  final double weight;

  Edge(this.from, this.to, this.weight);

  @override
  String toString() {
    return 'from: $from, to: $to, weight: $weight';
  }
}