import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../shared/widgets/themed_snackbar.dart';

class UndoAction {
  final String label;
  final Future<void> Function() restore;

  const UndoAction({
    required this.label,
    required this.restore,
  });
}

/// // UI-1: Service providing undo timeouts and snackbar feedback for destructive operations.
class UndoService {
  UndoService._internal();
  static final UndoService instance = UndoService._internal();

  Future<void> execute({
    required BuildContext context,
    required String message,
    required Future<void> Function() action,
    required Future<void> Function() undo,
    Duration duration = const Duration(seconds: 5),
    bool isDarkMode = true,
  }) async {
    bool undone = false;

    ThemedSnackbar.show(
      context,
      message: message,
      color: isDarkMode ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      isDarkMode: isDarkMode,
      actionLabel: 'UNDO',
      onAction: () async {
        undone = true;
        await undo();
      },
    );

    // Give user 5s window to press undo before permanent action commits
    await Future.delayed(duration);
    if (!undone) {
      await action();
    }
  }
}
