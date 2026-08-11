import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:logging/logging.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/provider/download_provider.dart';
import '../provider/settings_provider.dart';

abstract final class BackupHelper {
  static Future<String?> _showPasswordDialog(
    BuildContext context, {
    required bool isExport,
    required bool isRtl,
    required bool isDark,
  }) async {
    final accentColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor:
              isDark ? AppTheme.surfaceRaised : AppTheme.lightSurfaceRaised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: accentColor.withValues(alpha: 0.28),
              width: 1.0,
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.lock_outline_rounded,
                  color: accentColor,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isExport
                      ? (isRtl ? 'حماية النسخة الاحتياطية' : 'ENCRYPT BACKUP')
                      : (isRtl
                          ? 'فك تشفير النسخة الاحتياطية'
                          : 'DECRYPT BACKUP'),
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 16.0,
                    letterSpacing: 1.1,
                    fontFamily: 'Space Grotesk',
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isExport
                    ? (isRtl
                        ? 'أدخل كلمة مرور لتشفير ملف النسخ الاحتياطي (اتركه فارغاً للتصدير بدون تشفير):'
                        : 'Enter a password to encrypt the backup file (leave empty to export unencrypted):')
                    : (isRtl
                        ? 'هذا الملف مشفر. يرجى إدخال كلمة المرور لفك التشفير:'
                        : 'This backup file is encrypted. Enter the password to decrypt:'),
                style: TextStyle(
                  color: isDark
                      ? AppTheme.textSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 14.0,
                  height: 1.45,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.24),
                    width: 1,
                  ),
                ),
                child: TextField(
                  controller: controller,
                  obscureText: true,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.textPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 12.5,
                    fontFamily: 'Inter',
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: isRtl ? 'كلمة المرور' : 'Password',
                    hintStyle: TextStyle(
                      color:
                          isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                      fontSize: 12,
                      fontFamily: 'Inter',
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              onPressed: () => Navigator.pop(context, null),
              child: Text(
                isRtl ? 'إلغاء' : 'CANCEL',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(
                isExport
                    ? (isRtl ? 'تصدير' : 'EXPORT')
                    : (isRtl ? 'فك التشفير' : 'DECRYPT'),
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  static Future<bool?> _showImportOptionDialog(
    BuildContext context, {
    required bool isRtl,
    required bool isDark,
  }) async {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            width: 1.0,
          ),
        ),
        title: Text(
          isRtl ? 'خيارات الاستيراد' : 'IMPORT OPTIONS',
          style: TextStyle(
            color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
            fontWeight: FontWeight.bold,
            fontSize: 16.0,
            letterSpacing: 1.5,
          ),
        ),
        content: Text(
          isRtl
              ? 'كيف ترغب في استيراد سجلات التحميل؟\n• دمج: إضافة السجلات الجديدة والاحتفاظ بالحالية.\n• استبدال: مسح السجلات الحالية بالكامل وتطبيق الجديدة.'
              : 'How would you like to restore the download logs?\n• MERGE: Add new logs and keep existing ones.\n• REPLACE: Wipe all existing logs and apply the new ones.',
          style: TextStyle(
            color:
                isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
            fontSize: 14.0,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: Text(
              isRtl ? 'إلغاء' : 'CANCEL',
              style: TextStyle(
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 13.0,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              isRtl ? 'دمج' : 'MERGE',
              style: TextStyle(
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                fontWeight: FontWeight.bold,
                fontSize: 13.0,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isRtl ? 'استبدال' : 'REPLACE',
              style: TextStyle(
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                fontWeight: FontWeight.bold,
                fontSize: 13.0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static void exportBackup(
      BuildContext context, SettingsProvider settings) async {
    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final password = await _showPasswordDialog(
      context,
      isExport: true,
      isRtl: isRtl,
      isDark: isDark,
    );
    if (password == null) return;
    final cleanPassword = password.trim();
    final jsonStr = provider.exportBackupJson(
      password: cleanPassword.isNotEmpty ? cleanPassword : null,
    );
    await SharePlus.instance.share(
      ShareParams(text: jsonStr, subject: 'XDM Backup Signal Logs'),
    );
  }

  static void importBackup(
      BuildContext context, SettingsProvider settings) async {
    final isDark = settings.isDarkMode;
    final provider = Provider.of<DownloadProvider>(context, listen: false);
    final isRtl = L10n.isRtl(context);
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );
    if (result == null || result.files.single.path == null) return;
    if (!context.mounted) return;
    final replace = await _showImportOptionDialog(
      context,
      isRtl: isRtl,
      isDark: isDark,
    );
    if (replace == null) return;
    final file = File(result.files.single.path!);
    final fileSize = await file.length();
    const maxSizeBytes = 50 * 1024 * 1024;
    if (fileSize > maxSizeBytes) {
      if (context.mounted) {
        ThemedSnackbar.show(
          context,
          message: isRtl
              ? 'حجم ملف النسخة الاحتياطية كبير جداً (الحد الأقصى 50 ميجابايت)'
              : 'Backup file is too large (maximum 50 MB)',
          color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
          icon: Icons.error_outline,
          isDarkMode: isDark,
        );
      }
      return;
    }
    final jsonStr = await file.readAsString();
    bool isEncrypted = false;
    try {
      final bytes = base64Decode(jsonStr.trim());
      final magic = utf8.encode('XDMCRYPT');
      if (bytes.length >= magic.length) {
        isEncrypted = true;
        for (int i = 0; i < magic.length; i++) {
          if (bytes[i] != magic[i]) {
            isEncrypted = false;
            break;
          }
        }
      }
    } catch (e, st) {
      Logger('settings_screen')
          .warning('[settings_screen] operation failed', e, st);
    }
    String? password = '';
    if (isEncrypted) {
      if (!context.mounted) return;
      password = await _showPasswordDialog(
        context,
        isExport: false,
        isRtl: isRtl,
        isDark: isDark,
      );
      if (password == null) return;
    }
    final success = await provider.importBackupJson(
      jsonStr,
      replace: replace,
      password: password,
    );
    if (!context.mounted) return;
    ThemedSnackbar.show(
      context,
      message: success
          ? (isRtl
              ? 'تم استيراد النسخة الاحتياطية بنجاح'
              : 'Backup imported successfully')
          : (isRtl
              ? 'فشل استيراد النسخة الاحتياطية (تأكد من صحة كلمة المرور)'
              : 'Failed to import backup (check password)'),
      color: success
          ? (isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen)
          : (isDark ? AppTheme.neonRed : AppTheme.lightNeonRed),
      icon: success ? Icons.check_circle_outline : Icons.error_outline,
      isDarkMode: isDark,
    );
  }
}
