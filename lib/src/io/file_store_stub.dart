import 'dart:typed_data';

const bool hasFileSystem = false;

Future<Uint8List?> readFileAsBytes(String path) async =>
    throw UnsupportedError('File access is not available on this platform.');

Future<void> writeFileAsBytes(String path, List<int> bytes) async =>
    throw UnsupportedError('File access is not available on this platform.');
