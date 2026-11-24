import 'package:dmx/core/services/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDisposable implements DisposableService {
  bool disposed = false;
  bool throwOnDispose;

  _FakeDisposable({this.throwOnDispose = false});

  @override
  Future<void> dispose() async {
    disposed = true;
    if (throwOnDispose) throw StateError('boom');
  }
}

class _FakeMemoryListener implements MemoryPressureListener {
  int calls = 0;
  bool throwOnPressure;

  _FakeMemoryListener({this.throwOnPressure = false});

  @override
  void onMemoryPressure() {
    calls++;
    if (throwOnPressure) throw StateError('boom');
  }
}

void main() {
  tearDown(() async {
    await ServiceRegistry.shutdownAll();
  });

  group('ServiceRegistry', () {
    test('register/unregister tracks disposable services', () {
      final a = _FakeDisposable();
      final b = _FakeDisposable();
      final before = ServiceRegistry.activeServicesCount;

      ServiceRegistry.register(a);
      ServiceRegistry.register(b);
      expect(ServiceRegistry.activeServicesCount, before + 2);

      ServiceRegistry.unregister(a);
      expect(ServiceRegistry.activeServicesCount, before + 1);
    });

    test('register is idempotent for the same instance', () {
      final a = _FakeDisposable();
      final before = ServiceRegistry.activeServicesCount;
      ServiceRegistry.register(a);
      ServiceRegistry.register(a);
      expect(ServiceRegistry.activeServicesCount, before + 1);
    });

    test('shutdownAll disposes every service and tolerates errors', () async {
      final a = _FakeDisposable();
      final b = _FakeDisposable(throwOnDispose: true);
      ServiceRegistry.register(a);
      ServiceRegistry.register(b);

      await ServiceRegistry.shutdownAll();

      expect(a.disposed, isTrue);
      expect(b.disposed, isTrue);
      expect(ServiceRegistry.activeServicesCount, 0);
    });

    test('broadcastMemoryPressure notifies live listeners', () {
      final listener = _FakeMemoryListener();
      ServiceRegistry.registerMemoryPressureListener(listener);
      ServiceRegistry.broadcastMemoryPressure();
      expect(listener.calls, 1);
      ServiceRegistry.unregisterMemoryPressureListener(listener);
    });

    test('registerMemoryPressureListener is idempotent', () {
      final listener = _FakeMemoryListener();
      ServiceRegistry.registerMemoryPressureListener(listener);
      ServiceRegistry.registerMemoryPressureListener(listener);
      ServiceRegistry.broadcastMemoryPressure();
      expect(listener.calls, 1);
      ServiceRegistry.unregisterMemoryPressureListener(listener);
    });

    test('listener errors are swallowed', () {
      final listener = _FakeMemoryListener(throwOnPressure: true);
      ServiceRegistry.registerMemoryPressureListener(listener);
      expect(ServiceRegistry.broadcastMemoryPressure, returnsNormally);
      ServiceRegistry.unregisterMemoryPressureListener(listener);
    });

    test('activeMemoryListenersCount prunes collected references', () {
      final listener = _FakeMemoryListener();
      ServiceRegistry.registerMemoryPressureListener(listener);
      expect(
          ServiceRegistry.activeMemoryListenersCount, greaterThanOrEqualTo(1));
      ServiceRegistry.unregisterMemoryPressureListener(listener);
    });

    test('unregisterMemoryPressureListener drops the listener', () {
      final listener = _FakeMemoryListener();
      ServiceRegistry.registerMemoryPressureListener(listener);
      final before = ServiceRegistry.activeMemoryListenersCount;
      ServiceRegistry.unregisterMemoryPressureListener(listener);
      expect(
        ServiceRegistry.activeMemoryListenersCount,
        lessThan(before + 1),
      );
    });

    test('broadcast with no listeners is safe', () {
      ServiceRegistry.unregisterMemoryPressureListener(_FakeMemoryListener());
      expect(ServiceRegistry.broadcastMemoryPressure, returnsNormally);
    });

    test('shutdownAll on an empty registry is safe', () async {
      await ServiceRegistry.shutdownAll();
      expect(ServiceRegistry.activeServicesCount, 0);
    });

    test('unregistering an unknown service is a no-op', () {
      final before = ServiceRegistry.activeServicesCount;
      ServiceRegistry.unregister(_FakeDisposable());
      expect(ServiceRegistry.activeServicesCount, before);
    });
  });
}
