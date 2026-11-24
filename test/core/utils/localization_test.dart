import 'package:dmx/core/utils/localization.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:dmx/features/settings/provider/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _withSettings(String lang, Widget Function(BuildContext) builder) {
  final settings = SettingsProvider.instance;
  settings.languageCode = lang;
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(home: Builder(builder: builder)),
  );
}

void main() {
  tearDown(() => SettingsProvider.instance.languageCode = 'en');

  group('L10n.translate', () {
    test('loads each supported locale', () {
      L10n.clearCacheForTesting();
      for (final lang in ['en', 'ar', 'es', 'fr', 'de']) {
        expect(L10n.translate(lang, 'close_btn'), isNotEmpty);
      }
    });

    test('returns the key when it exists in no locale', () {
      expect(L10n.translate('en', '__definitely_missing__'),
          '__definitely_missing__');
    });

    test('singularizes a *_plural key when count is 1', () {
      expect(
        L10n.translate('en', 'items_count_plural', args: {'count': 1}),
        '1 item',
      );
      // A double 1.0 is recognized as singular; the template still renders
      // the original argument value.
      expect(
        L10n.translate('en', 'items_count_plural', args: {'count': 1.0}),
        '1.0 item',
      );
      expect(
        L10n.translate('en', 'items_count_plural', args: {'count': '1'}),
        '1 item',
      );
    });

    test('keeps plural form for counts other than 1', () {
      expect(
        L10n.translate('en', 'items_count_plural', args: {'count': 3}),
        '3 items',
      );
    });

    test('substitutes named args into the template', () {
      expect(
        L10n.translate(
          'en',
          'waiting_for_slot',
          args: {'active': 2, 'max': 3},
        ),
        'Waiting for slot (2/3 active)',
      );
    });

    test('evicts the oldest locale once the cache is full', () {
      L10n.clearCacheForTesting();
      for (var i = 0; i < 25; i++) {
        expect(L10n.translate('lang_$i', 'close_btn'), isNotEmpty);
      }
      // The cache must remain usable after eviction.
      expect(L10n.translate('en', 'close_btn'), 'Close');
    });
  });

  group('L10n context helpers', () {
    testWidgets('of/isRtl/currentLang reflect the provider language',
        (tester) async {
      await tester.pumpWidget(
        _withSettings('en', (context) {
          expect(L10n.of(context, 'close_btn'), 'Close');
          expect(L10n.isRtl(context), isFalse);
          expect(L10n.currentLang, 'en');

          SettingsProvider.instance.languageCode = 'ar';
          expect(L10n.isRtl(context), isTrue);
          expect(L10n.of(context, 'close_btn'), isNot('Close'));
          expect(L10n.currentLang, 'ar');
          return const SizedBox();
        }),
      );
    });

    testWidgets('translateCategory localizes and normalizes empty categories',
        (tester) async {
      await tester.pumpWidget(
        _withSettings('en', (context) {
          expect(L10n.translateCategory(context, 'Video'), 'Video');
          expect(L10n.translateCategory(context, ''), 'Auto');

          SettingsProvider.instance.languageCode = 'ar';
          expect(L10n.translateCategory(context, 'Video'), 'فيديو');
          expect(L10n.translateCategory(context, 'Audio'), 'صوت');
          expect(L10n.translateCategory(context, 'Document'), 'مستند');
          expect(L10n.translateCategory(context, 'Archive'), 'أرشيف');
          expect(L10n.translateCategory(context, 'APK'), 'تطبيق');
          expect(L10n.translateCategory(context, 'App'), 'تطبيق');
          expect(L10n.translateCategory(context, 'Auto'), 'تلقائي');
          expect(L10n.translateCategory(context, 'Unknown'), 'أخرى');
          expect(L10n.translateCategory(context, ''), 'تلقائي');

          SettingsProvider.instance.languageCode = 'de';
          expect(L10n.translateCategory(context, 'Document'), 'Dokument');
          expect(L10n.translateCategory(context, 'Archive'), 'Archiv');
          expect(L10n.translateCategory(context, 'Auto'), 'Auto');
          expect(L10n.translateCategory(context, 'Unknown'), 'Sonstige');

          SettingsProvider.instance.languageCode = 'es';
          expect(L10n.translateCategory(context, 'Video'), 'Vídeo');
          expect(L10n.translateCategory(context, 'Document'), 'Documento');
          expect(L10n.translateCategory(context, 'Archive'), 'Archivo');
          expect(L10n.translateCategory(context, 'App'), 'Aplicación');
          expect(L10n.translateCategory(context, 'Unknown'), 'Otros');

          SettingsProvider.instance.languageCode = 'fr';
          expect(L10n.translateCategory(context, 'Video'), 'Vidéo');
          expect(L10n.translateCategory(context, 'Document'), 'Document');
          expect(L10n.translateCategory(context, 'Archive'), 'Archive');
          expect(L10n.translateCategory(context, 'App'), 'Application');
          expect(L10n.translateCategory(context, 'Unknown'), 'Autres');
          return const SizedBox();
        }),
      );
    });

    testWidgets('defaults to English when no provider is present',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(L10n.translateCategory(context, 'Video'), 'Video');
              expect(L10n.translateCategory(context, ''), 'Auto');
              expect(
                L10n.translateStatusName(context, DownloadStatus.downloading),
                'Downloading',
              );
              return const SizedBox();
            },
          ),
        ),
      );
    });

    testWidgets('translateStatus handles downloading and terminal states',
        (tester) async {
      await tester.pumpWidget(
        _withSettings('en', (context) {
          expect(
            L10n.translateStatus(context, DownloadStatus.downloading, '5m'),
            '5m left',
          );
          // English returns rawEta unchanged for non-downloading states.
          expect(
            L10n.translateStatus(context, DownloadStatus.completed, 'Seeding'),
            'Seeding',
          );

          SettingsProvider.instance.languageCode = 'ar';
          expect(
            L10n.translateStatus(
                context, DownloadStatus.downloading, '1h 2m 3s'),
            endsWith('متبقي'),
          );
          expect(
            L10n.translateStatus(context, DownloadStatus.completed, 'Seeding'),
            'مشاركة الملف (Seeding)',
          );
          expect(
            L10n.translateStatus(context, DownloadStatus.completed, 'x'),
            'مكتمل',
          );
          expect(L10n.translateStatus(context, DownloadStatus.queued, ''),
              'قيد الانتظار');
          expect(L10n.translateStatus(context, DownloadStatus.paused, ''),
              'متوقف مؤقتاً');
          expect(L10n.translateStatus(context, DownloadStatus.failed, ''),
              'فشل التنزيل');
          expect(L10n.translateStatus(context, DownloadStatus.merging, 'raw'),
              'raw');

          SettingsProvider.instance.languageCode = 'de';
          expect(
              L10n.translateStatus(context, DownloadStatus.downloading, '5m'),
              '5m übrig');
          expect(
            L10n.translateStatus(context, DownloadStatus.completed, 'Seeding'),
            'Am Seeden (Seeding)',
          );
          expect(L10n.translateStatus(context, DownloadStatus.completed, 'x'),
              'Abgeschlossen');
          expect(L10n.translateStatus(context, DownloadStatus.queued, ''),
              'In Warteschlange');
          expect(L10n.translateStatus(context, DownloadStatus.paused, ''),
              'Pausiert');
          expect(L10n.translateStatus(context, DownloadStatus.failed, ''),
              'Fehlgeschlagen');

          SettingsProvider.instance.languageCode = 'es';
          expect(
              L10n.translateStatus(context, DownloadStatus.downloading, '5m'),
              'quedan 5m');
          expect(
            L10n.translateStatus(context, DownloadStatus.completed, 'Seeding'),
            'Compartiendo (Seeding)',
          );
          expect(L10n.translateStatus(context, DownloadStatus.completed, 'x'),
              'Completado');
          expect(L10n.translateStatus(context, DownloadStatus.queued, ''),
              'En cola');
          expect(L10n.translateStatus(context, DownloadStatus.paused, ''),
              'Pausado');
          expect(L10n.translateStatus(context, DownloadStatus.failed, ''),
              'Fallido');

          SettingsProvider.instance.languageCode = 'fr';
          expect(
              L10n.translateStatus(context, DownloadStatus.downloading, '5m'),
              'il reste 5m');
          expect(
            L10n.translateStatus(context, DownloadStatus.completed, 'Seeding'),
            'Partage en cours (Seeding)',
          );
          expect(L10n.translateStatus(context, DownloadStatus.completed, 'x'),
              'Terminé');
          expect(L10n.translateStatus(context, DownloadStatus.queued, ''),
              'En attente');
          expect(L10n.translateStatus(context, DownloadStatus.paused, ''),
              'En pause');
          expect(L10n.translateStatus(context, DownloadStatus.failed, ''),
              'Échec');
          return const SizedBox();
        }),
      );
    });

    testWidgets('translateStatusName covers all statuses and locales',
        (tester) async {
      await tester.pumpWidget(
        _withSettings('en', (context) {
          expect(L10n.translateStatusName(context, DownloadStatus.downloading),
              'Downloading');
          expect(L10n.translateStatusName(context, DownloadStatus.completed),
              'Completed');
          expect(L10n.translateStatusName(context, DownloadStatus.paused),
              'Paused');
          expect(L10n.translateStatusName(context, DownloadStatus.queued),
              'Queued');
          expect(L10n.translateStatusName(context, DownloadStatus.failed),
              'Failed');
          expect(L10n.translateStatusName(context, DownloadStatus.merging),
              'Merging');

          SettingsProvider.instance.languageCode = 'ar';
          expect(L10n.translateStatusName(context, DownloadStatus.downloading),
              'جاري التحميل');
          expect(L10n.translateStatusName(context, DownloadStatus.merging),
              'جاري الدمج');

          SettingsProvider.instance.languageCode = 'de';
          expect(L10n.translateStatusName(context, DownloadStatus.downloading),
              'Wird geladen');
          expect(L10n.translateStatusName(context, DownloadStatus.merging),
              'Wird zusammengeführt');

          SettingsProvider.instance.languageCode = 'es';
          expect(L10n.translateStatusName(context, DownloadStatus.downloading),
              'Descargando');
          expect(L10n.translateStatusName(context, DownloadStatus.merging),
              'Combinando');

          SettingsProvider.instance.languageCode = 'fr';
          expect(L10n.translateStatusName(context, DownloadStatus.downloading),
              'Téléchargement');
          expect(L10n.translateStatusName(context, DownloadStatus.merging),
              'Fusion');
          return const SizedBox();
        }),
      );
    });
  });
}
