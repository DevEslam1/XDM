import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dmx/core/app_theme.dart';
import 'package:dmx/core/services/error_taxonomy.dart';
import 'package:dmx/shared/design/dmx_design.dart';

class ErrorRecoveryWidget extends StatefulWidget {
  const ErrorRecoveryWidget({
    super.key,
    required this.error,
    this.retryCount = 0,
    this.onRetry,
    this.onOpenSettings,
    this.onContactSupport,
    this.compact = false,
  });

  final Object error;
  final int retryCount;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onContactSupport;
  final bool compact;

  @override
  State<ErrorRecoveryWidget> createState() => _ErrorRecoveryWidgetState();
}

class _ErrorRecoveryWidgetState extends State<ErrorRecoveryWidget> {
  bool _expanded = false;
  bool _copied = false;

  Color _getCategoryColor(ErrorFamily family, bool isDark) {
    switch (family) {
      case ErrorFamily.network:
      case ErrorFamily.timeout:
        return Colors.blue;
      case ErrorFamily.disk:
        return Colors.orange;
      case ErrorFamily.auth:
        return isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
      case ErrorFamily.integrity:
        return Colors.purple;
      case ErrorFamily.server:
        return Colors.amber;
      default:
        return Colors.redAccent;
    }
  }

  IconData _getCategoryIcon(ErrorFamily family) {
    switch (family) {
      case ErrorFamily.network:
      case ErrorFamily.timeout:
        return Icons.wifi_off_rounded;
      case ErrorFamily.disk:
        return Icons.storage_rounded;
      case ErrorFamily.auth:
        return Icons.lock_outline_rounded;
      case ErrorFamily.integrity:
        return Icons.verified_user_outlined;
      case ErrorFamily.server:
        return Icons.dns_rounded;
      default:
        return Icons.error_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final classification = ErrorTaxonomy.classify(widget.error);
    final categoryColor = _getCategoryColor(classification.family, isDark);
    final categoryIcon = _getCategoryIcon(classification.family);

    if (widget.compact) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: categoryColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: categoryColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(categoryIcon, color: categoryColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                classification.message,
                style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 13,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.onRetry != null)
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                color: categoryColor,
                onPressed: widget.onRetry,
                tooltip: 'Retry',
              ),
          ],
        ),
      );
    }

    return DmxCardShell(
      accent: categoryColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: categoryColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(categoryIcon, color: categoryColor, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        classification.family.name.toUpperCase(),
                        style: TextStyle(
                          color: categoryColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        classification.message,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                    ],
                  ),
                ),
                if (widget.retryCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Retries: ${widget.retryCount}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.onRetry != null && classification.retryable)
                  ElevatedButton.icon(
                    onPressed: widget.onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: categoryColor,
                      foregroundColor: Colors.white,
                    ),
                  ),
                if (widget.onOpenSettings != null ||
                    classification.family == ErrorFamily.disk)
                  OutlinedButton.icon(
                    onPressed: widget.onOpenSettings,
                    icon: const Icon(Icons.settings_rounded, size: 18),
                    label: const Text('Open Settings'),
                  ),
                if (widget.onContactSupport != null)
                  TextButton.icon(
                    onPressed: widget.onContactSupport,
                    icon: const Icon(Icons.help_outline_rounded, size: 18),
                    label: const Text('Contact Support'),
                  ),
                TextButton.icon(
                  onPressed: () {
                    final diagnostics =
                        'Error Family: ${classification.family.name}\n'
                        'HTTP Status: ${classification.httpStatus}\n'
                        'Message: ${classification.message}\n'
                        'Raw Exception: ${widget.error}';
                    Clipboard.setData(ClipboardData(text: diagnostics));
                    setState(() => _copied = true);
                    Future.delayed(
                      const Duration(seconds: 2),
                      () => setState(() => _copied = false),
                    );
                  },
                  icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18),
                  label: Text(_copied ? 'Copied' : 'Copy Details'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text(
                      _expanded ? 'Hide Error Details' : 'Show Error Details',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: Theme.of(context).primaryColor,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  widget.error.toString(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ErrorRecoveryDialog extends StatelessWidget {
  const ErrorRecoveryDialog({
    super.key,
    required this.error,
    this.retryCount = 0,
    this.onRetry,
    this.onOpenSettings,
  });

  final Object error;
  final int retryCount;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;

  static Future<void> show(
    BuildContext context, {
    required Object error,
    int retryCount = 0,
    VoidCallback? onRetry,
    VoidCallback? onOpenSettings,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => ErrorRecoveryDialog(
        error: error,
        retryCount: retryCount,
        onRetry: onRetry,
        onOpenSettings: onOpenSettings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ErrorRecoveryWidget(
          error: error,
          retryCount: retryCount,
          onRetry: () {
            Navigator.of(context).pop();
            onRetry?.call();
          },
          onOpenSettings: () {
            Navigator.of(context).pop();
            onOpenSettings?.call();
          },
        ),
      ),
    );
  }
}
