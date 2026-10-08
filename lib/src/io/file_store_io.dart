import 'dart:io';
import 'dart:typed_data';

const bool hasFileSystem = true;

Future<Uint8List?> readFileAsBytes(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

Future<void> writeFileAsBytes(String path, List<int> bytes) async {
  // Write to a temporary file first so an interrupted write never leaves a
  // truncated cache behind.
  final tmp = File('$path.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(path);
}
