import 'package:flutter/material.dart';
import '../../../core/app_theme.dart';

/// Reusable error boundary widget providing fallback UI for screens.
/// Uses a GlobalKey to allow child widgets to signal errors via [SafeScreen.reportError].
class SafeScreen extends StatefulWidget {
  final Widget child;
  final String screenName;

  const SafeScreen({
    super.key,
    required this.child,
    required this.screenName,
  });

  /// Report an error to the nearest [SafeScreen] ancestor.
  static void reportError(BuildContext context, Object error) {
    final state = context.findAncestorStateOfType<_ErrorBoundaryState>();
    state?.captureError(error);
  }

  @override
  State<SafeScreen> createState() => _SafeScreenState();
}

class _SafeScreenState extends State<SafeScreen> {
  @override
  Widget build(BuildContext context) {
    return _ErrorBoundary(
      screenName: widget.screenName,
      child: widget.child,
    );
  }
}

class _ErrorBoundary extends StatefulWidget {
  final Widget child;
  final String screenName;

  const _ErrorBoundary({
    required this.child,
    required this.screenName,
  });

  @override
  State<_ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<_ErrorBoundary> {
  Object? _error;

  void captureError(Object error) {
    if (mounted) {
      setState(() {
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 48,
                  color: AppTheme.neonRed,
                ),
                const SizedBox(height: 16),
                Text(
                  'Error loading ${widget.screenName}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _error.toString(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _error = null;
                    });
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
