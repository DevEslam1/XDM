import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../app_theme.dart';
import 'localization.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../shared/widgets/themed_snackbar.dart';

Future<void> openFile(BuildContext context, String path, SettingsProvider settings) async {
  final isDark = settings.isDarkMode;
  try {
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && context.mounted) {
      ThemedSnackbar.show(
        context,
        message: '${L10n.isRtl(context) ? 'تعذر فتح الملف' : 'Could not open file'}: ${result.message}',
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
    }
  } catch (e) {
    if (context.mounted) {
      ThemedSnackbar.show(
        context,
        message: '${L10n.isRtl(context) ? 'خطأ في فتح الملف' : 'Error opening file'}: $e',
        color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
        icon: Icons.error_outline,
        isDarkMode: isDark,
      );
    }
  }
}
