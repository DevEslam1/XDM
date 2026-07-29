import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/downloads/models/download_task.dart';
import 'l10n/app_en.dart';
import 'l10n/app_ar.dart';

class L10n {
  static final Map<String, Map<String, String>> _cache = {};

  static Map<String, String> _loadLocale(String lang) {
    switch (lang) {
      case 'en':
        return enTranslations;
      case 'ar':
        return arTranslations;
      default:
        return enTranslations;
    }
  }

  static Map<String, String> _getTranslations(String lang) {
    return _cache.putIfAbsent(lang, () => _loadLocale(lang));
  }

  static String of(BuildContext context, String key, {bool listen = false}) {
    final lang = Provider.of<SettingsProvider>(
      context,
      listen: listen,
    ).languageCode;
    return _getTranslations(lang)[key] ?? key;
  }

  static String translate(String lang, String key) {
    return _getTranslations(lang)[key] ?? key;
  }

  static bool isRtl(BuildContext context, {bool listen = false}) {
    return Provider.of<SettingsProvider>(
          context,
          listen: listen,
        ).languageCode ==
        'ar';
  }

  static String translateCategory(BuildContext context, String cat) {
    if (!isRtl(context)) return cat;
    switch (cat) {
      case 'Video':
        return 'فيديو';
      case 'Audio':
        return 'صوت';
      case 'Document':
        return 'مستند';
      case 'Archive':
        return 'أرشيف';
      case 'APK':
        return 'تطبيق';
      default:
        return 'أخرى';
    }
  }

  static String translateStatus(
    BuildContext context,
    DownloadStatus status,
    String rawEta,
  ) {
    if (status == DownloadStatus.downloading) {
      if (!isRtl(context)) {
        return '$rawEta left';
      }
      return '${rawEta.replaceAllMapped(RegExp(r"(\d+)\s*h\b"), (m) => "${m[1]} ساعة").replaceAllMapped(RegExp(r"(\d+)\s*m\b"), (m) => "${m[1]} دقيقة").replaceAllMapped(RegExp(r"(\d+)\s*s\b"), (m) => "${m[1]} ثانية").trim()} متبقي';
    }
    if (!isRtl(context)) return rawEta;
    switch (status) {
      case DownloadStatus.completed:
        if (rawEta == 'Seeding') return 'مشاركة الملف (Seeding)';
        return 'مكتمل';
      case DownloadStatus.queued:
        return 'قيد الانتظار';
      case DownloadStatus.paused:
        return 'متوقف مؤقتاً';
      case DownloadStatus.failed:
        return 'فشل التنزيل';
      default:
        return rawEta;
    }
  }

  static String translateStatusName(
    BuildContext context,
    DownloadStatus status,
  ) {
    if (!isRtl(context)) {
      return switch (status) {
        DownloadStatus.downloading => 'Downloading',
        DownloadStatus.completed => 'Completed',
        DownloadStatus.paused => 'Paused',
        DownloadStatus.queued => 'Queued',
        DownloadStatus.failed => 'Failed',
      };
    }
    return switch (status) {
      DownloadStatus.downloading => 'جاري التحميل',
      DownloadStatus.completed => 'مكتمل',
      DownloadStatus.paused => 'موقوف مؤقتاً',
      DownloadStatus.queued => 'في الانتظار',
      DownloadStatus.failed => 'فشل الاتصال',
    };
  }
}
