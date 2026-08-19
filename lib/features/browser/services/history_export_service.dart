import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Clean service for exporting and sharing surfing and download history files.
class HistoryExportService {
  static final HistoryExportService instance = HistoryExportService._();
  HistoryExportService._();

  /// Encodes [items] as formatted JSON and saves to the app's temporary cache directory.
  Future<File> exportToJson(List<Map<String, dynamic>> items, String filename) async {
    final jsonStr = const JsonEncoder.withIndent('  ').convert(items);
    final tempDir = await getTemporaryDirectory();
    final file = File(p.join(tempDir.path, filename));
    await file.writeAsString(jsonStr);
    return file;
  }

  /// Triggers system share sheet for the given export [file].
  Future<void> shareHistoryFile(File file, String subject) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: subject,
      ),
    );
  }
}
