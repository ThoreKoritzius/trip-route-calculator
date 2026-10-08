import 'edge.dart';
import 'graph_codec.dart';
import 'node.dart';
import 'dart:convert';
import 'dart:typed_data';
import '../io/file_store.dart';

class Graph {
  final Map<int, Node> nodes = {};
  final Map<int, List<Edge>> adjacencyList = {};

  /// When the underlying OSM data was downloaded, if known. Files written
  /// before version 0.0.14 carry no timestamp.
  DateTime? createdAt;

  Graph({this.createdAt});

  /// Incremented on every change made through this class, so derived data
  /// (e.g. the spatial index used for snapping) knows when to rebuild. Call
  /// [markModified] after mutating [nodes]/[adjacencyList] directly.
  int get revision => _revision;
  int _revision = 0;

  void markModified() => _revision++;

  void addNode(Node node) {
    _revision++;
    nodes[node.id] = node;
    adjacencyList.putIfAbsent(node.id, () => []);
  }

  /// Adds an undirected edge (stored as two directed edges).
  void addEdge(Edge edge) {
    _revision++;
    adjacencyList[edge.from]?.add(edge);
    adjacencyList[edge.to]?.add(edge.reversed);
  }

  void removeNode(int nodeId) {
    _revision++;
    // Remove node
    nodes.remove(nodeId);

    // Remove edges efficiently
    final edgesToRemove = adjacencyList.remove(nodeId) ?? [];
    for (final edge in edgesToRemove) {
      adjacencyList[edge.to]?.removeWhere((e) => e.to == nodeId);
    }
  }

  /// Loads a graph previously written by [saveGraph] (binary, or the JSON
  /// format used up to 0.0.13).
  ///
  /// Throws if the file does not exist, cannot be parsed, or the platform has
  /// no file system (web).
  static Future<Graph> fromFile(String filePath) async {
    final bytes = await readFileAsBytes(filePath);
    if (bytes == null) {
      throw Exception('Graph file for $filePath not found.');
    }
    return Graph.fromBytes(bytes);
  }

  /// Decodes a graph from [toBytes] output or legacy JSON.
  factory Graph.fromBytes(Uint8List bytes) {
    if (GraphCodec.isBinary(bytes)) return GraphCodec.decode(bytes);
    return Graph.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
  }

  /// Compact binary encoding, see [GraphCodec].
  Uint8List toBytes() => GraphCodec.encode(this);

  /// Reconstructs a graph from the JSON written by [toJson].
  factory Graph.fromJson(Map<String, dynamic> graphJson) {
    final graph = Graph(
        createdAt: DateTime.tryParse('${graphJson['createdAt']}')?.toUtc());

    // Add nodes
    for (final nodeJson in graphJson['nodes']) {
      graph.addNode(Node(
        nodeJson['id'] as int,
        (nodeJson['lat'] as num).toDouble(),
        (nodeJson['lon'] as num).toDouble(),
        nodeJson['isFootWay'] == true,
      ));
    }

    // Add edges. The file already contains both directions of every edge,
    // so they are added as directed edges to avoid duplicating them.
    for (final edgeJson in graphJson['edges']) {
      final from = edgeJson['from'] as int;
      final to = edgeJson['to'] as int;
      if (!graph.nodes.containsKey(from) || !graph.nodes.containsKey(to)) {
        continue;
      }
      // Files written before edges carried the flag fall back to node flags.
      final isFootWay = edgeJson['isFootWay'] as bool? ??
          (graph.nodes[from]!.isFootWay && graph.nodes[to]!.isFootWay);
      graph.adjacencyList[from]!.add(Edge(
        from,
        to,
        (edgeJson['weight'] as num).toDouble(),
        isFootWay: isFootWay,
        isSteps: edgeJson['isSteps'] == true,
      ));
    }

    return graph;
  }

  /// Loads a graph from [filePath]. Prefer the static [Graph.fromFile].
  Future<Graph> loadGraph(String filePath) => Graph.fromFile(filePath);

  Map<String, dynamic> toJson() => {
        'format': 2,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
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
                'isFootWay': edge.isFootWay,
                if (edge.isSteps) 'isSteps': true,
              });
        }).toList(),
      };

  /// Saves the graph to [filePath] in the compact binary format, or as JSON
  /// if [asJson] is set.
  Future<void> saveGraph(String filePath, {bool asJson = false}) =>
      writeFileAsBytes(
          filePath, asJson ? utf8.encode(jsonEncode(toJson())) : toBytes());
}
