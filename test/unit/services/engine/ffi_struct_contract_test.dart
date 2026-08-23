import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/src/ffi_bindings.dart';

void main() {
  group('FFI Struct Contract Tests', () {
    test('LtTorrentStatus ABI contract size verification', () {
      // 1880 bytes is the ABI-2 layout (numComplete/numIncomplete present),
      // which is what every liblibtorrent_flutter binary in prebuilt/android/
      // actually writes. The literal is repeated deliberately: asserting only
      // against kExpectedStatusSize would let both sides drift together
      // silently.
      //
      // Do not "correct" this to 1872 by reading the export table. The shipped
      // binaries export only the 29 ABI-1 symbols but still use the ABI-2
      // struct, so the symbol list is not evidence about the layout. Dropping
      // the two swarm fields shifts numPieces..queuePosition 8 bytes early and
      // lands hasMetadata on native is_paused, which reads 0 for any running
      // torrent — a fully-known .torrent then reports "no metadata", the UI
      // shows 0/N files, and graceful pause is skipped.
      final actualSize = sizeOf<LtTorrentStatus>();
      expect(actualSize, equals(1880),
          reason:
              'LtTorrentStatus must be exactly 1880 bytes to match the shipped '
              'native bridge (actual: $actualSize). Adding or removing a field '
              'mid-struct shifts every field after it and decodes unrelated '
              'memory.');
      expect(kExpectedStatusSize, equals(1880));
      expect(
        () => verifyStatusStructContract(),
        returnsNormally,
      );
    });

    test('swarm counters occupy the two Int32s right after numSeeds', () {
      // Guards the exact insertion point that was previously removed. Writes a
      // distinct sentinel to each field, then reads the raw memory at the
      // offsets the native binary writes to. If hasMetadata stops landing at
      // 1872 it is reading native is_paused again.
      final p = calloc<LtTorrentStatus>();
      try {
        p.ref
          ..numSeeds = 0x11111111
          ..numComplete = 0x22222222
          ..numIncomplete = 0x33333333
          ..hasMetadata = 0x44444444
          ..queuePosition = 0x55555555;
        final words = p.cast<Int32>();
        expect(words[1844 ~/ 4], equals(0x11111111), reason: 'numSeeds @1844');
        expect(words[1848 ~/ 4], equals(0x22222222),
            reason: 'numComplete @1848');
        expect(words[1852 ~/ 4], equals(0x33333333),
            reason: 'numIncomplete @1852');
        expect(words[1872 ~/ 4], equals(0x44444444),
            reason: 'hasMetadata @1872 — 1864 means the swarm fields are gone');
        expect(words[1876 ~/ 4], equals(0x55555555),
            reason: 'queuePosition @1876');
      } finally {
        calloc.free(p);
      }
    });
  });

  group('BridgeAbiReport compatibility', () {
    BridgeAbiReport report({
      String rawVersion = '2.0.9',
      int? nativeAbi,
      int? nativeStatusSize,
      List<String> missingSymbols = const [],
    }) =>
        BridgeAbiReport(
          rawVersion: rawVersion,
          nativeAbi: nativeAbi,
          nativeStatusSize: nativeStatusSize,
          missingSymbols: missingSymbols,
        );

    test('an unmarked binary is ABI 1 and compatible', () {
      // The shipped binaries emit no bridge_abi= marker. That absence *is*
      // ABI 1, the revision the bindings are pinned to — not a fault.
      final r = report();
      expect(r.reportsAbi, isFalse);
      expect(r.effectiveNativeAbi, equals(1));
      expect(r.isCompatible, isTrue);
      expect(r.describe(), contains('OK'));
    });

    test('absent optional exports do not make the bridge incompatible', () {
      // Regression guard: these 15 exports are expected to be missing. Letting
      // them flip isCompatible false is what suppressed all status data.
      final r = report(missingSymbols: const [
        'lt_save_resume_data',
        'lt_get_trackers',
        'lt_get_file_progress',
      ]);
      expect(r.isCompatible, isTrue);
      expect(r.hasDegradedFeatures, isTrue);
      expect(r.describe(), contains('report unavailable'));
    });

    test('a newer ABI-2 binary is flagged incompatible', () {
      // Struct grew to 1880 there, so decoding it with the pinned 1872-byte
      // layout would silently corrupt every field past numSeeds.
      final r = report(nativeAbi: 2, nativeStatusSize: 1880);
      expect(r.isCompatible, isFalse);
      expect(r.describe(), contains('INCOMPATIBLE'));
    });

    test('a size disagreement at the pinned ABI is flagged', () {
      final r = report(nativeAbi: 1, nativeStatusSize: 1880);
      expect(r.statusSizeMatches, isFalse);
      expect(r.isCompatible, isFalse);
    });

    test('libtorrentVersion strips the bridge markers', () {
      final r = report(
        rawVersion: '2.0.9;bridge_abi=1;status_size=1872',
        nativeAbi: 1,
        nativeStatusSize: 1872,
      );
      expect(r.libtorrentVersion, equals('2.0.9'));
      expect(r.isCompatible, isTrue);
    });
  });
}
