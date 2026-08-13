import 'package:flutter/material.dart';
import 'package:dmx/core/services/diagnostic_service.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/core/services/logging_service.dart';
import 'package:dmx/shared/widgets/error_recovery_widget.dart';

class UnifiedErrorPresenter {
  UnifiedErrorPresenter._();

  static final _logger = LoggingService.logger('UnifiedErrorPresenter');

  static Color getCategoryColor(ErrorFamily family) {
    switch (family) {
      case ErrorFamily.network:
      case ErrorFamily.timeout:
        return Colors.blue;
      case ErrorFamily.disk:
        return Colors.orange;
      case ErrorFamily.auth:
        return Colors.red;
      case ErrorFamily.integrity:
        return Colors.purple;
      case ErrorFamily.server:
        return Colors.amber;
      default:
        return Colors.redAccent;
    }
  }

  static void _logError(Object error, String presenterType) {
    _logger.warning('Presenter [$presenterType] displayed error: $error');
    try {
      DiagnosticService.instance.record(presenterType, error.toString(), error: error);
    } catch (_) {}
  }

  static Widget showInlineError(
    BuildContext context,
    Object error, {
    VoidCallback? onRetry,
  }) {
    _logError(error, 'Inline');
    return ErrorRecoveryWidget(
      error: error,
      compact: true,
      onRetry: onRetry,
    );
  }

  static Future<void> showDialogError(
    BuildContext context,
    Object error, {
    VoidCallback? onRetry,
    VoidCallback? onOpenSettings,
  }) async {
    _logError(error, 'Dialog');
    return ErrorRecoveryDialog.show(
      context,
      error: error,
      onRetry: onRetry,
      onOpenSettings: onOpenSettings,
    );
  }

  static void showSnackbarError(
    BuildContext context,
    Object error, {
    VoidCallback? onRetry,
    Duration duration = const Duration(seconds: 4),
  }) {
    _logError(error, 'Snackbar');
    final classification = ErrorTaxonomy.classify(error);
    final color = getCategoryColor(classification.family);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: color,
        duration: duration,
        content: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                classification.message,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        action: onRetry != null && classification.retryable
            ? SnackBarAction(
                label: 'RETRY',
                textColor: Colors.white,
                onPressed: onRetry,
              )
            : null,
      ),
    );
  }

  static Widget showFullScreenError(
    BuildContext context,
    Object error, {
    VoidCallback? onRetry,
  }) {
    _logError(error, 'FullScreen');
    final classification = ErrorTaxonomy.classify(error);
    final color = getCategoryColor(classification.family);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded, size: 72, color: color),
              const SizedBox(height: 16),
              Text(
                classification.family.name.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                classification.message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),
              if (onRetry != null)
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
