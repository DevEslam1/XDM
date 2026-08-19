import 'dart:async';
import 'package:dio/dio.dart';

/// A utility class that provides delays that can be cancelled via a Dio CancelToken.
/// This prevents memory leaks and ensures immediate cancellation of downloads
/// during retry backoffs without managing manual timer maps.
class CancellableDelayer {
  final CancelToken? _cancelToken;

  CancellableDelayer([this._cancelToken]);

  /// Delays for [duration], resolving early if [_cancelToken] is cancelled.
  Future<void> delay(Duration duration) async {
    if (_cancelToken?.isCancelled == true) return;

    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    // Listen to cancellation and complete immediately if cancelled
    _cancelToken?.whenCancel.then((_) {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await completer.future;
    } finally {
      timer.cancel();
    }
  }
}
