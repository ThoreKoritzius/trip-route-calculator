// Platform-specific file access: dart:io where available, otherwise (web) a
// stub that reports that no file system is available.
export 'file_store_stub.dart' if (dart.library.io) 'file_store_io.dart';
