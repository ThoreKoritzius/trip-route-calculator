const bool hasFileSystem = false;

Future<String?> readFileAsString(String path) async =>
    throw UnsupportedError('File access is not available on this platform.');

Future<void> writeFileAsString(String path, String contents) async =>
    throw UnsupportedError('File access is not available on this platform.');
