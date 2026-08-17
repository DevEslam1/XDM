import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../services/browser_controller.dart';
import '../widgets/browser_find_panel.dart';
import '../widgets/browser_home_dashboard.dart';
import '../widgets/browser_misc_dialogs.dart';
import '../widgets/browser_shield_sheet.dart';
import '../widgets/browser_tab_strip.dart';
import '../widgets/browser_tab_switcher.dart';
import '../widgets/browser_tab_view.dart';
import '../widgets/browser_toolbar.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver, HapticHelper {
  BrowserController? _controller;
  bool _isControllerOwned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      final settings = context.read<SettingsProvider>();
      final downloads = context.read<DownloadProvider>();
      final db = context.read<DatabaseService>();

      _controller = BrowserController(
        settingsProvider: settings,
        downloadProvider: downloads,
        databaseService: db,
      );
      _isControllerOwned = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller?.handleAppLifecycleState(state);
  }

  @override
  void didHaveMemoryPressure() {
    _controller?.tabManager.onMemoryPressure();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isControllerOwned) {
      _controller?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return ChangeNotifierProvider<BrowserController>.value(
      value: controller,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyT, control: true):
              _NewTabIntent(),
          SingleActivator(LogicalKeyboardKey.keyW, control: true):
              _CloseTabIntent(),
          SingleActivator(LogicalKeyboardKey.keyR, control: true):
              _ReloadIntent(),
          SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _FindIntent(),
          SingleActivator(LogicalKeyboardKey.keyL, control: true):
              _FocusUrlIntent(),
          SingleActivator(LogicalKeyboardKey.tab, control: true):
              _NextTabIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _NewTabIntent: CallbackAction<_NewTabIntent>(
              onInvoke: (_) => controller.openInNewTab('about:blank', switchTo: true),
            ),
            _CloseTabIntent: CallbackAction<_CloseTabIntent>(
              onInvoke: (_) {
                if (controller.activeTab != null) {
                  controller.closeTab(controller.activeTab!.id);
                }
                return null;
              },
            ),
            _ReloadIntent: CallbackAction<_ReloadIntent>(
              onInvoke: (_) => controller.reload(),
            ),
            _FindIntent: CallbackAction<_FindIntent>(
              onInvoke: (_) => controller.openFindPanel(),
            ),
            _FocusUrlIntent: CallbackAction<_FocusUrlIntent>(
              onInvoke: (_) => controller.focusNode.requestFocus(),
            ),
            _NextTabIntent: CallbackAction<_NextTabIntent>(
              onInvoke: (_) {
                if (controller.tabs.length > 1) {
                  final nextIdx = (controller.currentIndex + 1) % controller.tabs.length;
                  controller.switchTab(nextIdx);
                }
                return null;
              },
            ),
          },
          child: RepaintBoundary(
            child: GeometricGridBackground(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: SafeArea(
                  child: Column(
                    children: [
                      // Top Toolbar (Scoped Selector)
                      Selector<BrowserController, ({bool isLoading, bool canGoBack, bool isHome, int tabCount, bool isHttps})>(
                        selector: (_, c) {
                          final activeTab = c.activeTab;
                          return (
                            isLoading: activeTab?.isLoading ?? false,
                            canGoBack: activeTab?.canGoBack ?? false,
                            isHome: activeTab?.isHome ?? true,
                            tabCount: c.tabs.length,
                            isHttps: activeTab?.isSecure ?? false,
                          );
                        },
                        builder: (context, state, _) {
                          final activeTab = controller.activeTab;

                          return BrowserToolbar(
                            controller: controller,
                            urlController: controller.urlController,
                            focusNode: controller.focusNode,
                            isDark: isDark,
                            isRtl: isRtl,
                            isLoading: state.isLoading,
                            canGoBack: state.canGoBack,
                            isHomeTab: state.isHome,
                            tabCount: state.tabCount,
                            desktopMode: settings.desktopMode,
                            textClr: textClr,
                            settings: settings,
                            isHttps: state.isHttps,
                            onGoBack: () => controller.goBack(),
                            onShowTabSwitcher: () => BrowserTabSwitcher.show(
                              context,
                              controller: controller,
                              settings: settings,
                              isDark: isDark,
                              textClr: textClr,
                            ),
                            onNavigateHome: () => controller.loadHome(),
                            onNavigate: (url) => controller.navigateToUrl(url),
                            onReload: () => controller.reload(),
                            onStopLoading: () => controller.stopLoading(),
                            onShieldPressed: () {
                              if (activeTab != null) {
                                BrowserShieldSheet.show(
                                  context: context,
                                  currentUrl: activeTab.url,
                                  blockedAdsCount: controller.blockedAdsCount(activeTab.id),
                                  blockedPopupsCount: controller.blockedPopupsCount(activeTab.id),
                                  onReloadTab: () => controller.reload(),
                                );
                              }
                            },
                            onQuitPressed: () => BrowserMiscDialogs.showCloseOrQuitDialog(
                              context,
                              settings: settings,
                              onHide: () {
                                context.read<DownloadProvider>().setActiveTabIndex(0);
                                if (Navigator.of(context).canPop()) {
                                  Navigator.of(context).pop();
                                }
                              },
                              onTerminate: () async {
                                await controller.quitBrowser(context: context);
                              },
                            ),
                          );
                        },
                      ),

                      // Incognito Mode Banner (Scoped Selector)
                      Selector<BrowserController, ({bool isIncognito, bool bannerDismissed})>(
                        selector: (_, c) => (
                          isIncognito: c.activeTab?.isIncognito ?? false,
                          bannerDismissed: c.incognitoBannerDismissed,
                        ),
                        builder: (context, incognitoState, _) {
                          if (incognitoState.isIncognito &&
                              !incognitoState.bannerDismissed) {
                            return Container(
                              width: double.infinity,
                              color: isDark
                                  ? const Color(0xFF1E1E2C)
                                  : const Color(0xFFE8EAF6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.visibility_off_rounded,
                                      size: 16, color: AppTheme.neonBlue),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      isRtl
                                          ? 'وضع التصفح المتخفي: لا يتم حفظ السجل أو ملفات تعريف الارتباط'
                                          : 'Incognito Mode: History and cookies are not saved',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: isDark
                                            ? AppTheme.textPrimary
                                            : AppTheme.lightTextPrimary,
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () =>
                                        controller.dismissIncognitoBanner(),
                                    child:
                                        const Icon(Icons.close_rounded, size: 16),
                                  ),
                                ],
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),

                      // Horizontal Tab Strip
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => BrowserTabStrip(
                          controller: controller,
                          settings: settings,
                          isDark: isDark,
                          textClr: textClr,
                        ),
                      ),

                      // Find-in-page panel (Scoped Selector)
                      Selector<BrowserController, bool>(
                        selector: (_, c) => c.findPanelVisible,
                        builder: (context, isVisible, _) {
                          if (!isVisible) return const SizedBox.shrink();
                          return BrowserFindPanel(
                            controller: controller,
                            settings: settings,
                          );
                        },
                      ),

                      // Reader Controls Toolbar (Scoped Selector)
                      Selector<BrowserController, bool>(
                        selector: (_, c) => c.readerControlsVisible,
                        builder: (context, isVisible, _) {
                          if (!isVisible) {
                            return const SizedBox.shrink();
                          }
                          return _ReaderControlsToolbar(
                            controller: controller,
                            isDark: isDark,
                            textClr: textClr,
                            isRtl: isRtl,
                          );
                        },
                      ),

                      // Content Stack
                      Expanded(
                        child: RepaintBoundary(
                          child: ListenableBuilder(
                            listenable: controller,
                            builder: (context, _) {
                              if (controller.isRestoring) {
                                return Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(20),
                                        decoration: BoxDecoration(
                                          color: (isDark
                                                  ? AppTheme.neonBlue
                                                  : AppTheme.lightNeonBlue)
                                              .withValues(alpha: 0.12),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.tab_rounded,
                                          size: 40,
                                          color: isDark
                                              ? AppTheme.neonBlue
                                              : AppTheme.lightNeonBlue,
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      Text(
                                        L10n.of(context, 'browser_restoring_tabs'),
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: textClr,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      SizedBox(
                                        width: 140,
                                        child: LinearProgressIndicator(
                                          backgroundColor: (isDark
                                                  ? Colors.white
                                                  : Colors.black)
                                              .withValues(alpha: 0.1),
                                          valueColor: AlwaysStoppedAnimation<Color>(
                                            isDark
                                                ? AppTheme.neonBlue
                                                : AppTheme.lightNeonBlue,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              final tabs = controller.tabs;
                              final currentIndex = controller.currentIndex;
                              final activeTab = controller.activeTab;

                              if (activeTab == null || activeTab.isHome) {
                                return BrowserHomeDashboard(
                                  controller: controller,
                                  settings: settings,
                                );
                              }

                              // Selective Offstage mounting: only mount active tab + LRU tabs (P2)
                              final mountedTabIds = controller.lruTabIds.toSet();
                              if (!mountedTabIds.contains(activeTab.id)) {
                                mountedTabIds.add(activeTab.id);
                              }

                              return Stack(
                                children: tabs.map((tab) {
                                  final isActive = (tabs.indexOf(tab) == currentIndex);
                                  final shouldMount = mountedTabIds.contains(tab.id);

                                  if (!shouldMount && !isActive) {
                                    return const SizedBox.shrink();
                                  }

                                  return Offstage(
                                    offstage: !isActive,
                                    child: BrowserTabView(
                                      tab: tab,
                                      controller: controller,
                                      settings: settings,
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderControlsToolbar extends StatelessWidget {
  final BrowserController controller;
  final bool isDark;
  final Color textClr;
  final bool isRtl;

  const _ReaderControlsToolbar({
    required this.controller,
    required this.isDark,
    required this.textClr,
    required this.isRtl,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final bg = isDark ? AppTheme.cardBg : AppTheme.lightCardBg;
    final border = isDark ? AppTheme.border : AppTheme.lightBorder;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: border, width: 0.8)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.text_decrease_rounded, size: 18),
            onPressed: () {
              final newSize = (controller.readerFontSize - 2.0).clamp(12.0, 28.0);
              controller.setReaderFontSize(newSize);
            },
            tooltip: 'Decrease font size',
          ),
          Text(
            '${controller.readerFontSize.round()}px',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textClr),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase_rounded, size: 18),
            onPressed: () {
              final newSize = (controller.readerFontSize + 2.0).clamp(12.0, 28.0);
              controller.setReaderFontSize(newSize);
            },
            tooltip: 'Increase font size',
          ),
          const Spacer(),
          _themeChip('light', const Color(0xFFFFFFFF)),
          const SizedBox(width: 6),
          _themeChip('sepia', const Color(0xFFFBF0D9)),
          const SizedBox(width: 6),
          _themeChip('dark', const Color(0xFF1E1E1E)),
          const Spacer(),
          ChoiceChip(
            label: Text(
              controller.readerFontFamily == 'serif' ? 'Serif' : 'Sans',
              style: const TextStyle(fontSize: 11),
            ),
            selected: true,
            selectedColor: accent.withValues(alpha: 0.15),
            onSelected: (_) {
              controller.setReaderFontFamily(
                controller.readerFontFamily == 'serif' ? 'sans-serif' : 'serif',
              );
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => controller.setReaderControlsVisible(false),
            tooltip: 'Close reader controls',
          ),
        ],
      ),
    );
  }

  Widget _themeChip(String theme, Color bg) {
    final isSelected = controller.readerTheme == theme;
    return GestureDetector(
      onTap: () => controller.setReaderTheme(theme),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? AppTheme.neonBlue : Colors.grey.withValues(alpha: 0.4),
            width: isSelected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}

class _NewTabIntent extends Intent {
  const _NewTabIntent();
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}

class _ReloadIntent extends Intent {
  const _ReloadIntent();
}

class _FindIntent extends Intent {
  const _FindIntent();
}

class _FocusUrlIntent extends Intent {
  const _FocusUrlIntent();
}

class _NextTabIntent extends Intent {
  const _NextTabIntent();
}
