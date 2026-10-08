import 'dart:typed_data';

import 'edge.dart';
import 'graph.dart';
import 'node.dart';

/// Compact binary encoding of a [Graph] (about 4x smaller and much faster to
/// load than JSON).
///
/// Layout (little endian), arrays ordered by element size so every typed
/// view is aligned:
///
///     magic "TRG1" | version u32 | createdAt ms f64 (NaN = unknown)
///     nodeCount u32 | edgeCount u32 | reserved u32
///     node ids f64[n] | lat f64[n] | lon f64[n]
///     edge from-index u32[e] | to-index u32[e] | weight f32[e]
///     node flags u8[n] | edge flags u8[e]
///
/// Node ids are stored as doubles (exact up to 2^53) so that decoding also
/// works where 64-bit integer lists are unavailable (web). Edges are stored
/// directed, exactly as in [Graph.adjacencyList].
class GraphCodec {
  static const _magic = [0x54, 0x52, 0x47, 0x31]; // "TRG1"
  static const _version = 1;
  static const _headerBytes = 32;

  static const _footWay = 1;
  static const _steps = 2;

  static bool isBinary(Uint8List bytes) =>
      bytes.length >= _headerBytes &&
      bytes[0] == _magic[0] &&
      bytes[1] == _magic[1] &&
      bytes[2] == _magic[2] &&
      bytes[3] == _magic[3];

  static Uint8List encode(Graph graph) {
    final nodes = graph.nodes.values.toList(growable: false);
    final index = <int, int>{
      for (var i = 0; i < nodes.length; i++) nodes[i].id: i
    };
    final edges = [
      for (final list in graph.adjacencyList.values)
        for (final edge in list)
          if (index.containsKey(edge.from) && index.containsKey(edge.to)) edge
    ];
    final n = nodes.length, e = edges.length;

    final size = _headerBytes + 24 * n + 12 * e + n + e;
    final bytes = Uint8List(size);
    final data = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, _magic);
    data.setUint32(4, _version, Endian.little);
    data.setFloat64(
        8,
        graph.createdAt?.millisecondsSinceEpoch.toDouble() ?? double.nan,
        Endian.little);
    data.setUint32(16, n, Endian.little);
    data.setUint32(20, e, Endian.little);

    var offset = _headerBytes;
    for (final read in <double Function(Node)>[
      (node) => node.id.toDouble(),
      (node) => node.lat,
      (node) => node.lon,
    ]) {
      for (final node in nodes) {
        data.setFloat64(offset, read(node), Endian.little);
        offset += 8;
      }
    }
    for (final edge in edges) {
      data.setUint32(offset, index[edge.from]!, Endian.little);
      offset += 4;
    }
    for (final edge in edges) {
      data.setUint32(offset, index[edge.to]!, Endian.little);
      offset += 4;
    }
    for (final edge in edges) {
      data.setFloat32(offset, edge.weight, Endian.little);
      offset += 4;
    }
    for (final node in nodes) {
      bytes[offset++] = node.isFootWay ? _footWay : 0;
    }
    for (final edge in edges) {
      bytes[offset++] =
          (edge.isFootWay ? _footWay : 0) | (edge.isSteps ? _steps : 0);
    }
    return bytes;
  }

  static Graph decode(Uint8List bytes) {
    if (!isBinary(bytes)) throw const FormatException('Not a TRG1 graph file');
    // Typed views need aligned offsets; copy if the buffer is unaligned.
    if (bytes.offsetInBytes % 8 != 0) bytes = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(bytes);
    final version = data.getUint32(4, Endian.little);
    if (version != _version) {
      throw FormatException('Unsupported graph file version $version');
    }
    final createdAtMs = data.getFloat64(8, Endian.little);
    final n = data.getUint32(16, Endian.little);
    final e = data.getUint32(20, Endian.little);
    if (bytes.length < _headerBytes + 24 * n + 12 * e + n + e) {
      throw const FormatException('Truncated graph file');
    }

    // Typed views use host byte order, which is little endian on every
    // platform Flutter supports.
    final buffer = bytes.buffer;
    var offset = bytes.offsetInBytes + _headerBytes;
    Float64List f64(int count) {
      final view = buffer.asFloat64List(offset, count);
      offset += 8 * count;
      return view;
    }

    Uint32List u32(int count) {
      final view = buffer.asUint32List(offset, count);
      offset += 4 * count;
      return view;
    }

    final ids = f64(n), lats = f64(n), lons = f64(n);
    final from = u32(e), to = u32(e);
    final weights = buffer.asFloat32List(offset, e);
    offset += 4 * e;
    final nodeFlags = buffer.asUint8List(offset, n);
    offset += n;
    final edgeFlags = buffer.asUint8List(offset, e);

    final graph = Graph(
        createdAt: createdAtMs.isNaN
            ? null
            : DateTime.fromMillisecondsSinceEpoch(createdAtMs.toInt(),
                isUtc: true));
    final nodeIds = List<int>.generate(n, (i) => ids[i].toInt());
    final adjacency = List<List<Edge>>.generate(n, (_) => <Edge>[]);
    for (var i = 0; i < n; i++) {
      graph.nodes[nodeIds[i]] =
          Node(nodeIds[i], lats[i], lons[i], nodeFlags[i] & _footWay != 0);
    }
    for (var i = 0; i < e; i++) {
      final flags = edgeFlags[i];
      adjacency[from[i]].add(Edge(nodeIds[from[i]], nodeIds[to[i]], weights[i],
          isFootWay: flags & _footWay != 0, isSteps: flags & _steps != 0));
    }
    for (var i = 0; i < n; i++) {
      graph.adjacencyList[nodeIds[i]] = adjacency[i];
    }
    return graph;
  }
}
