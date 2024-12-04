import 'edge.dart';
import 'node.dart';

class Graph {
  final Map<int, Node> nodes = {};
  final Map<int, List<Edge>> adjacencyList = {};

  void addNode(Node node) {
    nodes[node.id] = node;
    adjacencyList[node.id] = [];
  }

  void addEdge(Edge edge) {
    adjacencyList[edge.from]?.add(edge);
    adjacencyList[edge.to]?.add(Edge(edge.to, edge.from, edge.weight));
  }

  void removeNode(int nodeId) {
    // Remove node
    nodes.remove(nodeId);

    // Remove edges efficiently
    final edgesToRemove = adjacencyList.remove(nodeId) ?? [];
    for (final edge in edgesToRemove) {
      adjacencyList[edge.to]?.removeWhere((e) => e.to == nodeId);
    }
  }
}
