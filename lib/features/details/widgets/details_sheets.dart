import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/checksum_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_tokens.dart';
import '../../../shared/widgets/dmx_bottom_sheet.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';

/// Styled delete confirmation dialog for removing a download task.
/// Keeps [AlertDialog] semantics for widget-test compatibility.
Future<bool?> showDetailsDeleteTaskDialog(
  BuildContext context,
  DownloadTask task,
  SettingsProvider settings,
) {
  final isDark = settings.isDarkMode;
  final isAmoled = settings.isAmoledMode;
  final isRtl = L10n.isRtl(context);
  final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
  final surfaceClr =
      AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true);
  final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);
  bool deleteFiles = false;

  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (dialogCtx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return Directionality(
            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            child: AlertDialog(
              backgroundColor: surfaceClr,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusXl),
                side: BorderSide(color: borderClr, width: DmxTokens.borderThin),
              ),
              title: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: redClr.withValues(alpha: isDark ? 0.14 : 0.10),
                      borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
                    ),
                    child: Icon(Icons.delete_outline_rounded,
                        color: redClr, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      L10n.of(ctx, 'delete_title'),
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        color: redClr,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
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
                    isRtl
                        ? 'هل أنت متأكد من حذف "${task.fileName}" من القائمة؟'
                        : 'Are you sure you want to remove "${task.fileName}" from the list?',
                    style: TextStyle(
                      fontFamily: AppTheme.fontBody,
                      color: AppTheme.textSecondaryOf(isDark),
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                      onTap: () => setState(() => deleteFiles = !deleteFiles),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.panelBg(isDark, isAmoled: isAmoled),
                          borderRadius:
                              BorderRadius.circular(DmxTokens.radiusMd),
                          border: Border.all(
                            color: borderClr,
                            width: DmxTokens.borderThin,
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: deleteFiles,
                                activeColor: redClr,
                                side: BorderSide(
                                  color: AppTheme.hairlineBorder(
                                    isDark,
                                    isAmoled: isAmoled,
                                    strong: true,
                                  ),
                                  width: 1.2,
                                ),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => deleteFiles = val);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                L10n.of(ctx, 'delete_files_label'),
                                style: TextStyle(
                                  fontFamily: AppTheme.fontBody,
                                  color: AppTheme.textPrimaryOf(isDark),
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSecondaryOf(isDark),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    ),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    L10n.of(ctx, 'cancel_btn'),
                    style: const TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: redClr,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                    ),
                  ),
                  onPressed: () => Navigator.of(ctx)
                      .pop({'confirmed': true, 'deleteFiles': deleteFiles}),
                  child: Text(
                    L10n.of(ctx, 'delete_btn'),
                    style: const TextStyle(
                      fontFamily: AppTheme.fontDisplay,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  ).then((result) {
    if (result != null && result['confirmed'] == true) {
      return result['deleteFiles'] as bool;
    }
    return null;
  });
}

/// Styled warning dialog when changing thread count on a task with existing progress.
Future<void> showDetailsThreadResetDialog({
  required BuildContext context,
  required SettingsProvider settings,
  required VoidCallback onConfirmReset,
}) {
  final isDark = settings.isDarkMode;
  final isAmoled = settings.isAmoledMode;
  final isRtl = L10n.isRtl(context);
  final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
  final surfaceClr =
      AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true);
  final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

  return showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: surfaceClr,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusXl),
        side: BorderSide(color: borderClr, width: DmxTokens.borderThin),
      ),
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: redClr.withValues(alpha: isDark ? 0.14 : 0.10),
              borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
            ),
            child: Icon(Icons.warning_amber_rounded, color: redClr, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              L10n.of(dialogCtx, 'details_threads_warning_title'),
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: redClr,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
      content: Text(
        L10n.of(dialogCtx, 'details_threads_warning_desc'),
        style: TextStyle(
          fontFamily: AppTheme.fontBody,
          color: AppTheme.textSecondaryOf(isDark),
          fontSize: 13.5,
          height: 1.45,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            runHaptic(settings);
            Navigator.pop(dialogCtx);
          },
          child: Text(
            L10n.of(dialogCtx, 'cancel_btn'),
            style: TextStyle(
              fontFamily: AppTheme.fontDisplay,
              color: AppTheme.textSecondaryOf(isDark),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: redClr,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
            ),
          ),
          onPressed: () {
            runHaptic(settings);
            Navigator.pop(dialogCtx);
            onConfirmReset();
          },
          child: Text(
            isRtl ? 'نعم، أعد التعيين' : 'YES, RESET',
            style: const TextStyle(
              fontFamily: AppTheme.fontDisplay,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Styled URL update dialog keeping [AlertDialog] semantics for widget tests.
Future<void> showDetailsUpdateUrlDialog({
  required BuildContext context,
  required DownloadTask task,
  required DownloadProvider provider,
  required SettingsProvider settings,
}) async {
  final isDark = settings.isDarkMode;
  final isAmoled = settings.isAmoledMode;
  final isRtl = L10n.isRtl(context);
  final accentClr = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
  final surfaceClr =
      AppTheme.surfaceColor(isDark, isAmoled: isAmoled, elevated: true);
  final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

  final textController = TextEditingController(text: task.url);
  final hasAudio =
      task.mergedAudioUrl != null && task.mergedAudioUrl!.isNotEmpty;
  final audioTextController =
      hasAudio ? TextEditingController(text: task.mergedAudioUrl) : null;

  InputDecoration buildInputDecoration(String? hint) {
    return InputDecoration(
      filled: true,
      fillColor: AppTheme.panelBg(isDark, isAmoled: isAmoled),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintText: hint,
      hintStyle: TextStyle(
        fontFamily: AppTheme.fontBody,
        color: AppTheme.textMutedOf(isDark),
        fontSize: 12.5,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        borderSide: BorderSide(color: borderClr, width: DmxTokens.borderThin),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        borderSide: BorderSide(color: borderClr, width: DmxTokens.borderThin),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
        borderSide: BorderSide(color: accentClr, width: 1.4),
      ),
    );
  }

  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: surfaceClr,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DmxTokens.radiusXl),
          side: BorderSide(color: borderClr, width: DmxTokens.borderThin),
        ),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accentClr.withValues(alpha: isDark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(DmxTokens.badgeRadius),
              ),
              child: Icon(Icons.link_rounded, color: accentClr, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isRtl ? 'تحديث رابط التحميل' : 'UPDATE DOWNLOAD LINK',
                style: TextStyle(
                  fontFamily: AppTheme.fontDisplay,
                  color: accentClr,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
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
              isRtl
                  ? 'أدخل الرابط الجديد لمتابعة التحميل:'
                  : 'Enter the new URL to continue downloading:',
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                color: AppTheme.textSecondaryOf(isDark),
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              maxLines: hasAudio ? 2 : 3,
              style: TextStyle(
                fontFamily: AppTheme.fontBody,
                color: AppTheme.textPrimaryOf(isDark),
                fontSize: 12.5,
              ),
              decoration: buildInputDecoration(hasAudio ? 'Video URL' : null),
            ),
            if (hasAudio && audioTextController != null) ...[
              const SizedBox(height: 10),
              TextField(
                controller: audioTextController,
                maxLines: 2,
                style: TextStyle(
                  fontFamily: AppTheme.fontBody,
                  color: AppTheme.textPrimaryOf(isDark),
                  fontSize: 12.5,
                ),
                decoration:
                    buildInputDecoration('Audio Stream URL (Optional)'),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              runHaptic(settings);
              Navigator.pop(dialogContext);
            },
            child: Text(
              L10n.of(dialogContext, 'cancel_btn'),
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                color: AppTheme.textSecondaryOf(isDark),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accentClr,
              foregroundColor: AppTheme.inkOn(accentClr),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
              ),
            ),
            onPressed: () async {
              runHaptic(settings);
              final newUrl = textController.text.trim();
              final newAudio = audioTextController?.text.trim();
              if (newUrl.isEmpty) return;

              Navigator.pop(dialogContext);

              try {
                await provider.updateTaskUrl(
                  task.id,
                  newUrl,
                  newAudioUrl: (newAudio != null && newAudio.isNotEmpty)
                      ? newAudio
                      : null,
                );

                if (context.mounted) {
                  ThemedSnackbar.show(
                    context,
                    message: isRtl
                        ? 'تم تحديث الرابط بنجاح. يمكنك استئناف التحميل الآن.'
                        : 'Link updated successfully. You can resume download now.',
                    color:
                        isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                    icon: Icons.check_circle_outline,
                    isDarkMode: isDark,
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ThemedSnackbar.show(
                    context,
                    message: e.toString(),
                    color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                    icon: Icons.error_outline,
                    isDarkMode: isDark,
                  );
                }
              }
            },
            child: Text(
              isRtl ? 'تحديث' : 'UPDATE',
              style: const TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  } finally {
    audioTextController?.dispose();
    textController.dispose();
  }
}

/// Unified bottom sheet for deleting a single file from a torrent download.
Future<bool?> showDetailsDeleteTorrentFileSheet({
  required BuildContext context,
  required String fileName,
  required bool isDark,
  required bool isAmoled,
}) {
  final isRtl = L10n.isRtl(context);
  final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;

  return showDmxModalBottomSheet<bool>(
    context: context,
    builder: (sheetCtx) => DmxSheetContainer(
      isDark: isDark,
      isAmoled: isAmoled,
      accentColor: redClr,
      header: DmxSheetHeader(
        title: isRtl ? 'حذف الملف؟' : 'Delete File?',
        subtitle: fileName,
        icon: Icons.delete_forever_outlined,
        accentColor: redClr,
        isDark: isDark,
      ),
      footer: DmxSheetActionBar(
        isDark: isDark,
        isAmoled: isAmoled,
        secondaryLabel: isRtl ? 'إلغاء' : 'Cancel',
        onSecondary: () => Navigator.of(sheetCtx).pop(false),
        primaryLabel: isRtl ? 'حذف' : 'Delete',
        primaryDestructive: true,
        primaryIcon: Icons.delete_outline_rounded,
        onPrimary: () => Navigator.of(sheetCtx).pop(true),
      ),
      child: DmxSheetSection(
        isDark: isDark,
        isAmoled: isAmoled,
        accentColor: redClr,
        child: Text(
          isRtl
              ? 'هل تريد حذف "$fileName" من وحدة التخزين وإلغاء تحميله؟'
              : 'Are you sure you want to delete "$fileName" from storage and stop downloading it?',
          style: TextStyle(
            fontFamily: AppTheme.fontBody,
            fontSize: 13,
            height: 1.45,
            color: AppTheme.textSecondaryOf(isDark),
          ),
        ),
      ),
    ),
  );
}

/// Unified bottom sheet for SHA-256 integrity verification.
Future<void> showDetailsChecksumSheet(
  BuildContext context,
  DownloadTask task,
) {
  final settings = context.read<SettingsProvider>();
  final isDark = settings.isDarkMode;
  final isAmoled = settings.isAmoledMode;
  final isRtl = L10n.isRtl(context);

  return showDmxModalBottomSheet<void>(
    context: context,
    builder: (_) => _ChecksumVerificationSheet(
      task: task,
      isDark: isDark,
      isAmoled: isAmoled,
      isRtl: isRtl,
    ),
  );
}

class _ChecksumVerificationSheet extends StatefulWidget {
  final DownloadTask task;
  final bool isDark;
  final bool isAmoled;
  final bool isRtl;

  const _ChecksumVerificationSheet({
    required this.task,
    required this.isDark,
    required this.isAmoled,
    required this.isRtl,
  });

  @override
  State<_ChecksumVerificationSheet> createState() =>
      _ChecksumVerificationSheetState();
}

class _ChecksumVerificationSheetState
    extends State<_ChecksumVerificationSheet> {
  final TextEditingController _expectedController = TextEditingController();
  bool _isCalculating = true;
  String? _calculatedHash;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.task.expectedSha256 != null &&
        widget.task.expectedSha256!.isNotEmpty) {
      _expectedController.text = widget.task.expectedSha256!;
    }
    _calculateHash();
  }

  @override
  void dispose() {
    _expectedController.dispose();
    super.dispose();
  }

  Future<void> _calculateHash() async {
    setState(() {
      _isCalculating = true;
      _error = null;
    });

    final path = widget.task.localFilePath;
    if (path.isEmpty || !File(path).existsSync()) {
      setState(() {
        _isCalculating = false;
        _error = widget.isRtl
            ? 'الملف غير موجود على القرص'
            : 'File not found on disk';
      });
      return;
    }

    try {
      final hash = await ChecksumService.sha256File(path);
      if (mounted) {
        setState(() {
          _calculatedHash = hash;
          _isCalculating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCalculating = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final isAmoled = widget.isAmoled;
    final isRtl = widget.isRtl;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final greenClr = isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen;
    final redClr = isDark ? AppTheme.neonRed : AppTheme.lightNeonRed;
    final borderClr = AppTheme.hairlineBorder(isDark, isAmoled: isAmoled);

    final expected = _expectedController.text.trim().toLowerCase();
    final calculated = _calculatedHash?.toLowerCase();
    final hasExpected = expected.isNotEmpty;
    final isMatch = hasExpected && calculated != null && expected == calculated;

    return DmxSheetContainer(
      isDark: isDark,
      isAmoled: isAmoled,
      accentColor: accent,
      scrollable: true,
      header: DmxSheetHeader(
        title: isRtl ? 'التحقق من التكامل' : 'VERIFY INTEGRITY',
        subtitle: widget.task.fileName,
        icon: Icons.verified_outlined,
        accentColor: accent,
        isDark: isDark,
      ),
      footer: DmxSheetActionBar(
        isDark: isDark,
        isAmoled: isAmoled,
        primaryLabel: isRtl ? 'إغلاق' : 'CLOSE',
        primaryColor: accent,
        onPrimary: () => Navigator.of(context).pop(),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DmxSheetSection(
            isDark: isDark,
            isAmoled: isAmoled,
            title: isRtl
                ? 'المجموع الاختباري المحسوب (SHA-256)'
                : 'CALCULATED SHA-256',
            child: _isCalculating
                ? Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        isRtl ? 'جارٍ الحساب...' : 'Calculating...',
                        style: TextStyle(
                          fontFamily: AppTheme.fontBody,
                          color: AppTheme.textSecondaryOf(isDark),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  )
                : _error != null
                    ? Row(
                        children: [
                          Icon(Icons.error_outline_rounded,
                              color: redClr, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                fontFamily: AppTheme.fontBody,
                                color: redClr,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              _calculatedHash!,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: AppTheme.textPrimaryOf(isDark),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.copy_rounded,
                                size: 17, color: accent),
                            tooltip: isRtl ? 'نسخ' : 'Copy',
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _calculatedHash!),
                              );
                              ThemedSnackbar.show(
                                context,
                                message: isRtl
                                    ? 'تم نسخ المجموع الاختباري'
                                    : 'Checksum copied to clipboard',
                                color: greenClr,
                                icon: Icons.check_circle_outline,
                                isDarkMode: isDark,
                              );
                            },
                          ),
                        ],
                      ),
          ),
          const SizedBox(height: 14),
          DmxSheetSection(
            isDark: isDark,
            isAmoled: isAmoled,
            title: isRtl ? 'المجموع الاختباري المتوقع' : 'EXPECTED SHA-256',
            child: TextField(
              controller: _expectedController,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: AppTheme.textPrimaryOf(isDark),
              ),
              decoration: InputDecoration(
                hintText: isRtl
                    ? 'الصق المجموع الاختباري للمقارنة...'
                    : 'Paste expected hash to compare...',
                hintStyle: TextStyle(
                  fontFamily: AppTheme.fontBody,
                  fontSize: 12,
                  color: AppTheme.textMutedOf(isDark),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                filled: true,
                fillColor: AppTheme.surfaceColor(isDark, isAmoled: isAmoled),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  borderSide:
                      BorderSide(color: borderClr, width: DmxTokens.borderThin),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  borderSide:
                      BorderSide(color: borderClr, width: DmxTokens.borderThin),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                  borderSide: BorderSide(color: accent, width: 1.4),
                ),
              ),
            ),
          ),
          if (hasExpected && !_isCalculating && _calculatedHash != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: (isMatch ? greenClr : redClr)
                    .withValues(alpha: isDark ? 0.14 : 0.10),
                borderRadius: BorderRadius.circular(DmxTokens.radiusMd),
                border: Border.all(
                  color: (isMatch ? greenClr : redClr)
                      .withValues(alpha: isDark ? 0.35 : 0.30),
                  width: DmxTokens.borderThin,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isMatch
                        ? Icons.check_circle_rounded
                        : Icons.error_rounded,
                    color: isMatch ? greenClr : redClr,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isMatch
                          ? (isRtl
                              ? 'التكامل سليم ومطابق ✓'
                              : 'VERIFIED: Hashes match ✓')
                          : (isRtl
                              ? 'تحذير: المجموع الاختباري غير مطابق ✗'
                              : 'MISMATCH: Hashes do not match ✗'),
                      style: TextStyle(
                        fontFamily: AppTheme.fontDisplay,
                        color: isMatch ? greenClr : redClr,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
