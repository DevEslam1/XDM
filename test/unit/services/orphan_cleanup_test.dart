import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_orphan_test');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('orphan cleanup scans and deletes only orphaned files', () async {
    // 1. Setup active paths (as if they were in provider task list)
    final activeVideo = '${tempDir.path}/active_video.mp4';
    final activeAudio = '${tempDir.path}/active_audio.mp4';

    final activePaths = <String>{
      p.canonicalize('$activeVideo.dmxpart'),
      p.canonicalize(activeVideo),
      p.canonicalize('$activeAudio.dmxpart'),
      p.canonicalize(activeAudio),
    };

    // 2. Create actual active files on disk (part, state, journal, audio)
    final activePart = File('$activeVideo.dmxpart')..createSync();
    final activeState = File('$activeVideo.dmxstate')..createSync();
    final activeJournal = File('$activeVideo.journal')..createSync();

    final activeAudioPart = File('$activeAudio.audio')..createSync();
    final activeAudioState = File('$activeAudio.audio.dmxstate')..createSync();

    // 3. Create orphaned files on disk (part, state, journal, audio)
    final orphanVideo = '${tempDir.path}/orphan_video.mp4';
    final orphanAudio = '${tempDir.path}/orphan_audio.mp4';

    final orphanPart = File('$orphanVideo.dmxpart')..createSync();
    final orphanState = File('$orphanVideo.dmxstate')..createSync();
    final orphanJournal = File('$orphanVideo.journal')..createSync();

    final orphanAudioPart = File('$orphanAudio.audio')..createSync();
    final orphanAudioState = File('$orphanAudio.audio.dmxstate')..createSync();

    // 4. Create non-temporary normal files (should NEVER be deleted)
    final normalFile = File('${tempDir.path}/important_document.pdf')
      ..createSync();

    // 5. Run the cleanup algorithm
    final dir = Directory(tempDir.path);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.canonicalize(entity.path);

      final isOrphan = (name.endsWith('.dmxpart') ||
              name.endsWith('.dmxstate') ||
              name.endsWith('.journal') ||
              name.endsWith('.audio') ||
              name.endsWith('.audio.dmxstate')) &&
          !activePaths.any((pPath) => name.startsWith(
              pPath.replaceAll('.dmxpart', '').replaceAll('.dmxstate', '')));

      if (isOrphan) {
        await entity.delete();
      }
    }

    // 6. Verify assertions
    // Active files must still exist
    expect(activePart.existsSync(), isTrue);
    expect(activeState.existsSync(), isTrue);
    expect(activeJournal.existsSync(), isTrue);
    expect(activeAudioPart.existsSync(), isTrue);
    expect(activeAudioState.existsSync(), isTrue);

    // Normal non-temp files must still exist
    expect(normalFile.existsSync(), isTrue);

    // Orphaned files must be deleted
    expect(orphanPart.existsSync(), isFalse);
    expect(orphanState.existsSync(), isFalse);
    expect(orphanJournal.existsSync(), isFalse);
    expect(orphanAudioPart.existsSync(), isFalse);
    expect(orphanAudioState.existsSync(), isFalse);
  });
}
