import 'package:dmx/core/services/desktop_tray_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        switch (call.method) {
          case 'isMinimized':
          case 'isFocused':
          case 'isVisible':
          case 'isMaximized':
          case 'isFullScreen':
            return false;
          default:
            return null;
        }
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tray_manager'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('wakelock_plus'),
      (call) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tray_manager'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('wakelock_plus'),
      null,
    );
  });

  group('DesktopTrayService', () {
    test('init wires callbacks and menu actions fire them', () async {
      final service = DesktopTrayService.instance;
      var paused = 0;
      var resumed = 0;

      await service.init(
        onPauseAll: () => paused++,
        onResumeAll: () => resumed++,
      );

      service.onTrayMenuItemClick(MenuItem(key: 'pause_all'));
      expect(paused, 1);

      service.onTrayMenuItemClick(MenuItem(key: 'resume_all'));
      expect(resumed, 1);

      // Unknown key is a no-op.
      service.onTrayMenuItemClick(MenuItem(key: 'unknown'));

      // Re-init short-circuits once initialized.
      await service.init();

      await service.updateTooltip(active: 2, speed: '1.5 MB/s');
      service.onTrayIconMouseDown();
      service.onTrayIconRightMouseDown();
    });

    test('quit menu item triggers the exit path safely', () async {
      final service = DesktopTrayService.instance;
      await service.init();
      service.onTrayMenuItemClick(MenuItem(key: 'quit'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('show menu item is safe', () async {
      final service = DesktopTrayService.instance;
      await service.init();
      service.onTrayMenuItemClick(MenuItem(key: 'show'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('updateTooltip before init returns without error', () async {
      // The singleton may already be initialized by a prior test; this call
      // must be safe either way.
      await DesktopTrayService.instance.updateTooltip(active: 0, speed: '0');
    });
  });
}
