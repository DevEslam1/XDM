import 'package:path/path.dart' as p;
import 'url_utils.dart';
import 'file_utils.dart';
import '../../features/downloads/provider/download_provider.dart';

class DownloadUtils {
  static String resolveDownloadName(
    DownloadProvider provider,
    String url,
    String? suggestedName,
  ) {
    String finalFileName = suggestedName ?? '';
    if (finalFileName.isEmpty) {
      if (url.startsWith('magnet:')) {
        final parsed = parseMagnetUrl(url);
        finalFileName = parsed['name'] ?? 'Torrent Download';
      } else {
        finalFileName = fileNameFromUrl(url);
      }
    }

    String numberedName = finalFileName;
    final ext = p.extension(finalFileName);
    final base = p.basenameWithoutExtension(finalFileName);
    var counter = 1;
    while (provider.tasks.any(
      (t) => t.fileName.toLowerCase() == numberedName.toLowerCase(),
    )) {
      numberedName = '${base}_$counter$ext';
      counter++;
    }
    return numberedName;
  }

  static String resolveCategory(String? type, String fileName) {
    if (type == 'video') {
      return 'Video';
    } else if (type == 'audio') {
      return 'Audio';
    } else if (type == 'image') {
      return 'Image';
    } else {
      return categoryFromFileName(fileName);
    }
  }
}
