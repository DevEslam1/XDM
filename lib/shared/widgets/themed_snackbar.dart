import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'dmx_backdrop_filter.dart';

class ThemedSnackbar {
  static void show(
    BuildContext context, {
    required String message,
    required Color color,
    IconData? icon,
    bool isDarkMode = true,
  }) {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.removeCurrentSnackBar();
    scaffoldMessenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.all(12),
        content: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DmxBackdropFilter(
            sigmaX: 10,
            sigmaY: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: (isDarkMode ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: color.withValues(alpha: 0.4), width: 1.0),
                boxShadow: isDarkMode
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.08),
                          blurRadius: 10.0,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: color, size: 18),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: isDarkMode ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
