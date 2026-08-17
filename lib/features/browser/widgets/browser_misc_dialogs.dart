import 'dart:async';
import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import '../services/browser_controller.dart';

class BrowserMiscDialogs {
  BrowserMiscDialogs._();

  /// U19: Zoom dialog with 50%, 100%, 125%, 150%, 200% presets
  static void showZoomDialog(
    BuildContext context, {
    required BrowserController controller,
    required String host,
    required SettingsProvider settings,
  }) async {
    final isDark = settings.isDarkMode;
    final currentZoom = await controller.siteSettingsStore.getZoom(host);
    double localZoom = currentZoom;
    Timer? zoomDebounce;

    if (!context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              '${L10n.of(context, 'browser_page_zoom')} (${(localZoom * 100).round()}%)',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: localZoom.clamp(0.5, 3.0),
                  min: 0.5,
                  max: 3.0,
                  divisions: 25,
                  label: '${(localZoom * 100).round()}%',
                  onChanged: (val) {
                    setDialogState(() => localZoom = val);
                    zoomDebounce?.cancel();
                    zoomDebounce = Timer(const Duration(milliseconds: 300), () {
                      controller.setZoomLevel(host, val);
                    });
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [0.5, 1.0, 1.25, 1.5, 2.0].map((preset) {
                    final isSelected = (localZoom - preset).abs() < 0.05;
                    return ChoiceChip(
                      label: Text('${(preset * 100).round()}%'),
                      selected: isSelected,
                      onSelected: (_) {
                        setDialogState(() => localZoom = preset);
                        zoomDebounce?.cancel();
                        controller.setZoomLevel(host, preset);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  zoomDebounce?.cancel();
                  Navigator.pop(dialogCtx);
                },
                child: Text(L10n.of(context, 'done_btn')),
              ),
            ],
          );
        },
      ),
    );
  }

  /// B15 & B6: JS / CSS Injector dialog with bounded height, persistence, and controller disposal
  static void showJsCssInjectorDialog(
    BuildContext context, {
    required BrowserController controller,
    required BrowserTab tab,
    required SettingsProvider settings,
  }) async {
    final isDark = settings.isDarkMode;
    final host = tab.host;
    final siteSettings = await controller.siteSettingsStore.getForHost(host);
    final jsController = TextEditingController(
      text: (siteSettings.customJs ?? []).join('\n'),
    );
    final cssController = TextEditingController(
      text: (siteSettings.customCss ?? []).join('\n'),
    );
    int activeTabIndex = 0;

    if (!context.mounted) {
      jsController.dispose();
      cssController.dispose();
      return;
    }

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
            title: Text(L10n.of(context, 'browser_js_css_injector')),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('JavaScript'),
                        selected: activeTabIndex == 0,
                        onSelected: (_) => setDialogState(() => activeTabIndex = 0),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('CSS'),
                        selected: activeTabIndex == 1,
                        onSelected: (_) => setDialogState(() => activeTabIndex = 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 180,
                    child: activeTabIndex == 0
                        ? TextField(
                            controller: jsController,
                            maxLines: null,
                            expands: true,
                            decoration: const InputDecoration(
                              hintText: '// Enter JavaScript to execute...',
                              border: OutlineInputBorder(),
                            ),
                          )
                        : TextField(
                            controller: cssController,
                            maxLines: null,
                            expands: true,
                            decoration: const InputDecoration(
                              hintText: '/* Enter CSS to inject... */',
                              border: OutlineInputBorder(),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text(L10n.of(context, 'cancel_btn')),
              ),
              ElevatedButton(
                onPressed: () async {
                  final js = jsController.text.trim();
                  final css = cssController.text.trim();

                  final updatedJs = js.isNotEmpty ? [js] : <String>[];
                  final updatedCss = css.isNotEmpty ? [css] : <String>[];
                  await controller.siteSettingsStore.saveForHost(
                    host,
                    siteSettings.copyWith(
                      customJs: updatedJs,
                      customCss: updatedCss,
                    ),
                  );

                  if (activeTabIndex == 0 && js.isNotEmpty) {
                    tab.controller?.evaluateJavascript(source: js);
                  } else if (activeTabIndex == 1 && css.isNotEmpty) {
                    final escaped = css.replaceAll("'", r"\'").replaceAll('\n', ' ');
                    tab.controller?.evaluateJavascript(
                      source: "var s = document.createElement('style'); s.innerHTML = '$escaped'; document.head.appendChild(s);",
                    );
                  }
                  if (dialogCtx.mounted) {
                    Navigator.pop(dialogCtx);
                  }
                },
                child: Text(L10n.of(context, 'browser_apply_uppercase')),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      jsController.dispose();
      cssController.dispose();
    });
  }

  /// U3: Safe quit dialog with Hide Browser and Terminate Browser
  static void showCloseOrQuitDialog(
    BuildContext context, {
    required VoidCallback onHide,
    required VoidCallback onTerminate,
    required SettingsProvider settings,
  }) {
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        title: Row(
          children: [
            const Icon(Icons.power_settings_new_rounded, size: 22, color: AppTheme.neonRed),
            const SizedBox(width: 8),
            Text(isRtl ? 'جلسة المتصفح' : 'Browser Session'),
          ],
        ),
        content: Text(
          isRtl
              ? 'هل تريد إخفاء المتصفح والعودة للتطبيق مع الإبقاء على التبويبات المفتوحة، أم إنهاء جلسة المتصفح بالكامل؟'
              : 'Do you want to hide the browser and return to downloads while keeping your open tabs, or terminate the browser session completely?',
          style: TextStyle(
            color: (isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary).withValues(alpha: 0.8),
            fontSize: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(isRtl ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.neonBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(dialogCtx);
              onHide();
            },
            child: Text(isRtl ? 'إخفاء المتصفح' : 'Hide Browser'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.neonRed),
            onPressed: () {
              Navigator.pop(dialogCtx);
              onTerminate();
            },
            child: Text(isRtl ? 'إنهاء المتصفح' : 'Terminate Browser'),
          ),
        ],
      ),
    );
  }

  /// U12 & B6: Add shortcut dialog with URL validation and controller disposal
  static void showAddShortcutDialog(
    BuildContext context, {
    required Function(String title, String url) onAdd,
    required SettingsProvider settings,
  }) {
    final isDark = settings.isDarkMode;
    final titleController = TextEditingController();
    final urlController = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
            title: Text(L10n.of(context, 'browser_add_shortcut')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: L10n.of(context, 'title_label'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: InputDecoration(
                    labelText: 'URL (e.g. https://example.com)',
                    errorText: errorText,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text(L10n.of(context, 'cancel_btn')),
              ),
              ElevatedButton(
                onPressed: () {
                  final inputUrl = urlController.text.trim();
                  final uri = Uri.tryParse(inputUrl.contains('://') ? inputUrl : 'https://$inputUrl');
                  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
                    setDialogState(() {
                      errorText = L10n.of(context, 'add_download_invalid_url');
                    });
                    return;
                  }
                  onAdd(
                    titleController.text.trim().isNotEmpty ? titleController.text.trim() : uri.host,
                    uri.toString(),
                  );
                  Navigator.pop(dialogCtx);
                },
                child: Text(L10n.of(context, 'add_btn')),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      titleController.dispose();
      urlController.dispose();
    });
  }

  /// U17 & U3: Keyboard shortcut discovery dialog (strictly implemented shortcuts)
  static void showKeyboardShortcutsDialog(
    BuildContext context, {
    required SettingsProvider settings,
  }) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    final shortcuts = [
      {'key': 'Ctrl + T', 'desc': 'New Tab'},
      {'key': 'Ctrl + W', 'desc': 'Close Active Tab'},
      {'key': 'Ctrl + R', 'desc': 'Reload Page'},
      {'key': 'Ctrl + F', 'desc': 'Find in Page'},
      {'key': 'Ctrl + L', 'desc': 'Focus Address Bar'},
      {'key': 'Ctrl + Tab', 'desc': 'Switch to Next Tab'},
    ];

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
        title: Row(
          children: [
            const Icon(Icons.keyboard_rounded, size: 22),
            const SizedBox(width: 8),
            Text(L10n.of(context, 'browser_keyboard_shortcuts')),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: shortcuts.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final s = shortcuts[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isDark ? AppTheme.cardBg : AppTheme.lightCardBg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isDark ? AppTheme.border : AppTheme.lightBorder,
                        ),
                      ),
                      child: Text(
                        s['key']!,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.neonBlue,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        s['desc']!,
                        style: TextStyle(fontSize: 13, color: textClr),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(L10n.of(context, 'done_btn')),
          ),
        ],
      ),
    );
  }
}
