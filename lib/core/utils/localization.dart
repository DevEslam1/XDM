import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/downloads/models/download_task.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../services/crash_reporting_service.dart';
import 'l10n/app_ar.dart';
import 'l10n/app_de.dart';
import 'l10n/app_en.dart';
import 'l10n/app_es.dart';
import 'l10n/app_fr.dart';

class L10n {
  static final Map<String, Map<String, String>> _cache = {};

  static Map<String, String> _loadLocale(String lang) {
    switch (lang) {
      case 'en':
        return enTranslations;
      case 'ar':
        return arTranslations;
      case 'es':
        return esTranslations;
      case 'fr':
        return frTranslations;
      case 'de':
        return deTranslations;
      default:
        return enTranslations;
    }
  }

  static Map<String, String> _getTranslations(String lang) {
    return _cache.putIfAbsent(lang, () => _loadLocale(lang));
  }

  static String translate(
    String lang,
    String key, {
    Map<String, dynamic>? args,
  }) {
    var targetKey = key;
    if (args != null && args.containsKey('count')) {
      final rawCount = args['count'];
      final count = rawCount is int
          ? rawCount
          : (rawCount is num
              ? rawCount.toInt()
              : int.tryParse(rawCount.toString()));
      if (count == 1 && targetKey.endsWith('_plural')) {
        final singularKey = targetKey.substring(0, targetKey.length - 7);
        targetKey = singularKey;
      }
    }

    final trans = _getTranslations(lang);
    String? template;
    if (trans.containsKey(targetKey)) {
      template = trans[targetKey];
    } else if (trans.containsKey(key)) {
      template = trans[key];
    } else {
      template =
          _getTranslations('en')[targetKey] ?? _getTranslations('en')[key];
      if (template != null) {
        if (kDebugMode) {
          debugPrint(
              'P0-6: Missing localization key "$targetKey" in locale "$lang", using English fallback.');
        } else {
          CrashReportingService.addBreadcrumb(
            'Missing key "$targetKey" in "$lang", using EN fallback',
            category: 'l10n',
          );
        }
      }
    }

    if (template == null) {
      if (kDebugMode) {
        debugPrint('P0-6: Missing localization key "$key" in all locales.');
      }
      return key;
    }

    if (args != null && args.isNotEmpty) {
      var result = template;
      args.forEach((argKey, value) {
        result = result.replaceAll('{$argKey}', value.toString());
      });
      return result;
    }

    return template;
  }

  static String of(
    BuildContext context,
    String key, {
    bool listen = false,
    Map<String, dynamic>? args,
  }) {
    final lang = Provider.of<SettingsProvider>(
      context,
      listen: listen,
    ).languageCode;
    return translate(lang, key, args: args);
  }

  static bool isRtl(BuildContext context, {bool listen = false}) {
    return Provider.of<SettingsProvider>(
          context,
          listen: listen,
        ).languageCode ==
        'ar';
  }

  // FIX(H-20): Normalize empty category to "Auto" so it displays correctly
  // across LTR/RTL and appears in analytics/aggregation.
  static String translateCategory(BuildContext context, String cat) {
    final effectiveCat = cat.isEmpty ? 'Auto' : cat;
    if (!isRtl(context)) return effectiveCat;
    switch (effectiveCat) {
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
      case 'Auto':
        return 'تلقائي';
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
        DownloadStatus.merging => 'Merging',
      };
    }
    return switch (status) {
      DownloadStatus.downloading => 'جاري التحميل',
      DownloadStatus.completed => 'مكتمل',
      DownloadStatus.paused => 'موقوف مؤقتاً',
      DownloadStatus.queued => 'في الانتظار',
      DownloadStatus.failed => 'فشل الاتصال',
      DownloadStatus.merging => 'جاري الدمج',
    };
  }
}
