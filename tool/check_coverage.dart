// One-off coverage checker mirroring CI exclusions.
// Usage: dart run tool/check_coverage.dart [path/to/lcov.info]
import 'dart:io';

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : 'coverage/lcov.info';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing $path — run `flutter test --coverage` first.');
    exit(1);
  }

  final excludePatterns = [
    RegExp(r'\.g\.dart$'),
    RegExp(r'lib/main\.dart$'),
    RegExp(r'lib/core/app_theme\.dart$'),
    RegExp(r'lib/core/services/torrent_service_ffi\.dart$'),
    RegExp(r'lib/features/[^/]+/screens/'),
    RegExp(r'lib/features/[^/]+/widgets/'),
    RegExp(r'lib/shared/widgets/'),
  ];

  var total = 0;
  var hit = 0;
  String? currentFile;
  var fileTotal = 0;
  var fileHit = 0;
  var excluded = false;

  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.replaceAll('\\', '/');
    if (line.startsWith('SF:')) {
      if (currentFile != null && !excluded) {
        total += fileTotal;
        hit += fileHit;
      }
      currentFile = line.substring(3);
      fileTotal = 0;
      fileHit = 0;
      excluded = excludePatterns.any((p) => p.hasMatch(currentFile!));
    } else if (!excluded && line.startsWith('DA:')) {
      final parts = line.substring(3).split(',');
      if (parts.length == 2) {
        fileTotal++;
        if (int.parse(parts[1]) > 0) fileHit++;
      }
    }
  }
  if (currentFile != null && !excluded) {
    total += fileTotal;
    hit += fileHit;
  }

  final pct = total == 0 ? 0.0 : (hit / total) * 100;
  stdout.writeln(
      'Core coverage: ${pct.toStringAsFixed(2)}% ($hit / $total lines)');
  exit(pct >= 38 ? 0 : 1);
}
