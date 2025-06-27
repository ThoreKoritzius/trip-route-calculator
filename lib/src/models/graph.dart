import 'edge.dart';
import 'node.dart';
import 'dart:convert';
import 'dart:io';

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

  Future<Graph> loadGraph(filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('Graph file for $filePath not found.');
    }

    // Read and parse JSON
    final jsonString = await file.readAsString();
    final Map<String, dynamic> graphJson = jsonDecode(jsonString);

    // Reconstruct Graph
    final graph = Graph();
    final nodeMap = <int, Node>{};

    // Add nodes
    for (final nodeJson in graphJson['nodes']) {
      final node = Node(
        nodeJson['id'],
        nodeJson['lat'],
        nodeJson['lon'],
        nodeJson['isFootWay'],
      );
      graph.addNode(node);
      nodeMap[node.id] = node;
    }

    // Add edges
    for (final edgeJson in graphJson['edges']) {
      final edge = Edge(
        edgeJson['from'],
        edgeJson['to'],
        edgeJson['weight'],
      );
      graph.addEdge(edge);
    }

    return graph;
  }

  Future<void> saveGraph(String filePath) async {
    final file = File(filePath);

    // Serialize Graph to JSON
    final graphJson = {
      'nodes': nodes.values
          .map((node) => {
                'id': node.id,
                'lat': node.lat,
                'lon': node.lon,
                'isFootWay': node.isFootWay,
              })
          .toList(),
      'edges': adjacencyList.entries.expand((entry) {
        return entry.value.map((edge) => {
              'from': edge.from,
              'to': edge.to,
              'weight': edge.weight,
            });
      }).toList(),
    };

    await file.writeAsString(jsonEncode(graphJson));
  }
}
