import 'dart:io';

import 'package:dmx/core/services/permission_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.root);
  final Directory root;

  @override
  Future<String?> getDownloadsPath() async => root.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;

  @override
  Future<String?> getTemporaryPath() async => root.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PermissionService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dmx_permission_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
    service = PermissionService();
    PermissionService.resetCachedSdkLevel();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PermissionService on desktop', () {
    test('storage permission is implicitly valid', () async {
      expect(await service.isStoragePermissionValid(), isTrue);
    });

    test('directory writability probe is inconclusive (null) off Android',
        () async {
      expect(await service.isDirectoryWritable(''), isNull);
      expect(await service.isDirectoryWritable(tempDir.path), isNull);
    });

    test('defaultDownloadDirectory creates an XDM folder', () async {
      final path = await service.defaultDownloadDirectory();
      expect(path, p.join(tempDir.path, 'XDM'));
      expect(await Directory(path).exists(), isTrue);
    });

    test('insertIntoMediaStore returns null off Android', () async {
      expect(
        await service.insertIntoMediaStore(
            'f.bin', 'application/octet-stream', '/tmp/f.bin'),
        isNull,
      );
    });

    test('ensureStorageAccess succeeds without permissions off Android',
        () async {
      expect(await service.ensureStorageAccess(), isTrue);
    });

    test('isStoragePermanentlyDenied is false off Android', () async {
      expect(await service.isStoragePermanentlyDenied(), isFalse);
    });

    test('battery optimization helpers return true off Android', () async {
      expect(await service.isBatteryOptimizationExempt(), isTrue);
      expect(await service.requestBatteryOptimizationExemption(), isTrue);
    });

    test('cached SDK level can be set and reset', () {
      PermissionService.setCachedSdkLevelForTesting(33);
      PermissionService.setCachedSdkLevelForTesting(null);
    });
  });
}
