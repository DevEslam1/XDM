import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
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
    if (_cache.length >= 20 && !_cache.containsKey(lang)) {
      _cache.remove(_cache.keys.first);
    }
    return _cache.putIfAbsent(lang, () => _loadLocale(lang));
  }

  @visibleForTesting
  static void clearCacheForTesting() => _cache.clear();

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

  /// Current language code without a BuildContext, for static helpers that
  /// cannot use `L10n.of(context)`. Falls back to English outside the tree.
  static String get currentLang {
    try {
      return SettingsProvider.instance.languageCode;
    } catch (_) {
      return 'en';
    }
  }

  static String _langOf(BuildContext context) {
    try {
      return Provider.of<SettingsProvider>(context, listen: false).languageCode;
    } catch (_) {
      return 'en';
    }
  }

  // FIX(H-20): Normalize empty category to "Auto" so it displays correctly
  // across LTR/RTL and appears in analytics/aggregation.
  static String translateCategory(BuildContext context, String cat) {
    final effectiveCat = cat.isEmpty ? 'Auto' : cat;
    switch (_langOf(context)) {
      case 'ar':
        return _categoryAr(effectiveCat);
      case 'de':
        return _categoryDe(effectiveCat);
      case 'es':
        return _categoryEs(effectiveCat);
      case 'fr':
        return _categoryFr(effectiveCat);
      default:
        return effectiveCat;
    }
  }

  static String _categoryAr(String cat) {
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
      case 'App':
        return 'تطبيق';
      case 'Auto':
        return 'تلقائي';
      default:
        return 'أخرى';
    }
  }

  static String _categoryDe(String cat) {
    switch (cat) {
      case 'Video':
        return 'Video';
      case 'Audio':
        return 'Audio';
      case 'Document':
        return 'Dokument';
      case 'Archive':
        return 'Archiv';
      case 'APK':
        return 'APK';
      case 'App':
        return 'App';
      case 'Auto':
        return 'Auto';
      default:
        return 'Sonstige';
    }
  }

  static String _categoryEs(String cat) {
    switch (cat) {
      case 'Video':
        return 'Vídeo';
      case 'Audio':
        return 'Audio';
      case 'Document':
        return 'Documento';
      case 'Archive':
        return 'Archivo';
      case 'APK':
        return 'APK';
      case 'App':
        return 'Aplicación';
      case 'Auto':
        return 'Auto';
      default:
        return 'Otros';
    }
  }

  static String _categoryFr(String cat) {
    switch (cat) {
      case 'Video':
        return 'Vidéo';
      case 'Audio':
        return 'Audio';
      case 'Document':
        return 'Document';
      case 'Archive':
        return 'Archive';
      case 'APK':
        return 'APK';
      case 'App':
        return 'Application';
      case 'Auto':
        return 'Auto';
      default:
        return 'Autres';
    }
  }

  static String translateStatus(
    BuildContext context,
    DownloadStatus status,
    String rawEta,
  ) {
    final lang = _langOf(context);
    if (status == DownloadStatus.downloading) {
      switch (lang) {
        case 'ar':
          return '${rawEta.replaceAllMapped(RegExp(r"(\d+)\s*h\b"), (m) => "${m[1]} ساعة").replaceAllMapped(RegExp(r"(\d+)\s*m\b"), (m) => "${m[1]} دقيقة").replaceAllMapped(RegExp(r"(\d+)\s*s\b"), (m) => "${m[1]} ثانية").trim()} متبقي';
        case 'de':
          return '$rawEta übrig';
        case 'es':
          return 'quedan $rawEta';
        case 'fr':
          return 'il reste $rawEta';
        default:
          return '$rawEta left';
      }
    }
    switch (lang) {
      case 'ar':
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
      case 'de':
        switch (status) {
          case DownloadStatus.completed:
            if (rawEta == 'Seeding') return 'Am Seeden (Seeding)';
            return 'Abgeschlossen';
          case DownloadStatus.queued:
            return 'In Warteschlange';
          case DownloadStatus.paused:
            return 'Pausiert';
          case DownloadStatus.failed:
            return 'Fehlgeschlagen';
          default:
            return rawEta;
        }
      case 'es':
        switch (status) {
          case DownloadStatus.completed:
            if (rawEta == 'Seeding') return 'Compartiendo (Seeding)';
            return 'Completado';
          case DownloadStatus.queued:
            return 'En cola';
          case DownloadStatus.paused:
            return 'Pausado';
          case DownloadStatus.failed:
            return 'Fallido';
          default:
            return rawEta;
        }
      case 'fr':
        switch (status) {
          case DownloadStatus.completed:
            if (rawEta == 'Seeding') return 'Partage en cours (Seeding)';
            return 'Terminé';
          case DownloadStatus.queued:
            return 'En attente';
          case DownloadStatus.paused:
            return 'En pause';
          case DownloadStatus.failed:
            return 'Échec';
          default:
            return rawEta;
        }
      default:
        return rawEta;
    }
  }

  static String translateStatusName(
    BuildContext context,
    DownloadStatus status,
  ) {
    switch (_langOf(context)) {
      case 'ar':
        return switch (status) {
          DownloadStatus.downloading => 'جاري التحميل',
          DownloadStatus.completed => 'مكتمل',
          DownloadStatus.paused => 'موقوف مؤقتاً',
          DownloadStatus.queued => 'في الانتظار',
          DownloadStatus.failed => 'فشل الاتصال',
          DownloadStatus.merging => 'جاري الدمج',
        };
      case 'de':
        return switch (status) {
          DownloadStatus.downloading => 'Wird geladen',
          DownloadStatus.completed => 'Abgeschlossen',
          DownloadStatus.paused => 'Pausiert',
          DownloadStatus.queued => 'In Warteschlange',
          DownloadStatus.failed => 'Fehlgeschlagen',
          DownloadStatus.merging => 'Wird zusammengeführt',
        };
      case 'es':
        return switch (status) {
          DownloadStatus.downloading => 'Descargando',
          DownloadStatus.completed => 'Completado',
          DownloadStatus.paused => 'Pausado',
          DownloadStatus.queued => 'En cola',
          DownloadStatus.failed => 'Fallido',
          DownloadStatus.merging => 'Combinando',
        };
      case 'fr':
        return switch (status) {
          DownloadStatus.downloading => 'Téléchargement',
          DownloadStatus.completed => 'Terminé',
          DownloadStatus.paused => 'En pause',
          DownloadStatus.queued => 'En attente',
          DownloadStatus.failed => 'Échec',
          DownloadStatus.merging => 'Fusion',
        };
      default:
        return switch (status) {
          DownloadStatus.downloading => 'Downloading',
          DownloadStatus.completed => 'Completed',
          DownloadStatus.paused => 'Paused',
          DownloadStatus.queued => 'Queued',
          DownloadStatus.failed => 'Failed',
          DownloadStatus.merging => 'Merging',
        };
    }
  }
}
