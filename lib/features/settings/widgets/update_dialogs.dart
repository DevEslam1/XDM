import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/update_service.dart';
import '../../../core/utils/localization.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

Future<void> showUpdateInfoDialog(
  BuildContext context,
  UpdateInfo update,
  DownloadProvider provider,
  SettingsProvider settings,
) async {
  final isDark = settings.isDarkMode;
  final isRtl = L10n.isRtl(context);

  final updatesDir = await UpdateService().getUpdatesDirectory();
  final fileName = 'XDM_${update.latestVersion}_v${update.versionCode}.apk';
  final apkFile = File('${updatesDir.path}/$fileName');
  final bool isDownloaded = await UpdateService().verifyApkIntegrity(
    apkFile,
    expectedSha256: update.sha256,
  );

  if (!context.mounted) return;

  showDialog(
    context: context,
    barrierDismissible: !update.mandatory,
    builder: (dialogCtx) {
      return AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.system_update_rounded,
              color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isRtl
                    ? 'تحديث جديد متوفر v${update.latestVersion}'
                    : 'New Update Available v${update.latestVersion}',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L10n.of(dialogCtx, 'update_changelog'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: isDark
                    ? AppTheme.textSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? Colors.black26 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? AppTheme.border : AppTheme.lightBorder,
                ),
              ),
              child: Text(
                update.changelog.isNotEmpty
                    ? update.changelog
                    : L10n.of(dialogCtx, 'update_general_fixes'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          if (!update.mandatory)
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(L10n.of(dialogCtx, 'btn_later')),
            ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
              foregroundColor: Colors.black,
            ),
            icon: Icon(
                isDownloaded ? Icons.install_mobile : Icons.download_rounded),
            label: Text(
              isDownloaded
                  ? L10n.of(dialogCtx, 'btn_install_now')
                  : L10n.of(dialogCtx, 'update_now_btn'),
            ),
            onPressed: () async {
              Navigator.pop(dialogCtx);
              if (isDownloaded) {
                await OpenFilex.open(apkFile.path);
              } else {
                await provider.startUpdateDownload(update);
              }
            },
          ),
        ],
      );
    },
  );
}

Future<void> showMandatoryUpdateDialog(
  BuildContext context,
  UpdateInfo update,
  DownloadProvider provider,
) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(L10n.of(dialogCtx, 'update_mandatory_title')),
          content: Text(
            '${L10n.of(dialogCtx, 'update_mandatory_title')}\n\n${update.changelog}',
          ),
          actions: [
            ElevatedButton(
              onPressed: () async {
                final updatesDir = await UpdateService().getUpdatesDirectory();
                final fileName =
                    'XDM_${update.latestVersion}_v${update.versionCode}.apk';
                final apkFile = File('${updatesDir.path}/$fileName');
                if (await apkFile.exists()) {
                  await OpenFilex.open(apkFile.path);
                } else {
                  await provider.startUpdateDownload(update);
                }
              },
              child: Text(L10n.of(dialogCtx, 'update_now_btn')),
            ),
          ],
        ),
      );
    },
  );
}
