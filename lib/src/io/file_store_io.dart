import 'dart:io';

const bool hasFileSystem = true;

Future<String?> readFileAsString(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<void> writeFileAsString(String path, String contents) async {
  // Write to a temporary file first so an interrupted write never leaves a
  // truncated cache behind.
  final tmp = File('$path.tmp');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(path);
}
