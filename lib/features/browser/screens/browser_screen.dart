import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/widgets/media_quality_sheet.dart';
import '../../add_download/widgets/youtube_playlist_sheet.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import '../services/browser_controller.dart';
import '../services/media_sniffer.dart';
import '../services/picture_in_picture_service.dart';
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
    // FIX(B6): Create the controller in initState instead of
    // didChangeDependencies. context.read() is safe here (it does not register
    // an inherited-widget dependency), and this avoids rebuilding/leaking the
    // controller if dependencies change.
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

    // FIX(P1): Provide the controller through the widget tree so inner chrome
    // sections can use Selector<BrowserController, X> to rebuild only when the
    // specific data they depend on changes.
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
              onInvoke: (_) =>
                  controller.openInNewTab('about:blank', switchTo: true),
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
                  final nextIdx =
                      (controller.currentIndex + 1) % controller.tabs.length;
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
                      // FIX(P1): ONE ListenableBuilder drives the whole chrome.
                      // Inner Selectors in _BrowserChrome rebuild only the
                      // sections whose specific data actually changed.
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => _BrowserChrome(
                          controller: controller,
                          settings: settings,
                          isDark: isDark,
                          isRtl: isRtl,
                          textClr: textClr,
                        ),
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
                                        L10n.of(
                                            context, 'browser_restoring_tabs'),
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
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
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

                              // FIX(P2): Only the active tab + LRU tabs are ever
                              // built. Every other tab returns SizedBox.shrink()
                              // so its (expensive) BrowserTabView subtree is
                              // never created — Offstage would still build/layout
                              // the child.
                              final mountedTabIds =
                                  controller.lruTabIds.toSet();
                              mountedTabIds.add(activeTab.id);

                              // FIX(U4): Swipe horizontally to switch between
                              // open tabs. Only active when there is more than
                              // one tab so a single tab never steals gestures.
                              final hasMultipleTabs = tabs.length > 1;

                              Widget tabContent = Stack(
                                children: tabs.map((tab) {
                                  final isActive =
                                      (tabs.indexOf(tab) == currentIndex);
                                  final shouldMount =
                                      mountedTabIds.contains(tab.id);

                                  if (!shouldMount) {
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

                              if (hasMultipleTabs) {
                                tabContent = RawGestureDetector(
                                  gestures: {
                                    HorizontalDragGestureRecognizer:
                                        GestureRecognizerFactoryWithHandlers<
                                            HorizontalDragGestureRecognizer>(
                                      () => HorizontalDragGestureRecognizer(),
                                      (instance) {
                                        instance.onEnd = (details) {
                                          final velocity =
                                              details.primaryVelocity ?? 0;
                                          // Ignore slow/ambiguous drags so web
                                          // page gestures aren't hijacked.
                                          if (velocity.abs() < 300) return;
                                          if (velocity < 0) {
                                            final next = currentIndex + 1;
                                            if (next < tabs.length) {
                                              controller.switchTab(next);
                                            }
                                          } else {
                                            final prev = currentIndex - 1;
                                            if (prev >= 0) {
                                              controller.switchTab(prev);
                                            }
                                          }
                                        };
                                      },
                                    ),
                                  },
                                  child: tabContent,
                                );
                              }

                              return tabContent;
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

class _BrowserChrome extends StatelessWidget {
  final BrowserController controller;
  final SettingsProvider settings;
  final bool isDark;
  final bool isRtl;
  final Color textClr;

  const _BrowserChrome({
    required this.controller,
    required this.settings,
    required this.isDark,
    required this.isRtl,
    required this.textClr,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // FIX(P1): Toolbar rebuilds only when the specific values it renders
        // change (progress, loading, nav state, tab count), not on every notify.
        Selector<BrowserController,
            (bool, bool, bool, bool, double, int, bool, bool)>(
          shouldRebuild: (a, b) => a != b,
          selector: (_, c) {
            final t = c.activeTab;
            return (
              t?.isHome ?? true,
              t?.isLoading ?? false,
              t?.canGoBack ?? false,
              t?.isSecure ?? false,
              t?.progress ?? 0.0,
              c.tabs.length,
              settings.desktopMode,
              c.incognitoBannerDismissed,
            );
          },
          builder: (context, data, _) {
            final (
              isHome,
              isLoading,
              canGoBack,
              isHttps,
              progress,
              tabCount,
              desktopMode,
              _
            ) = data;
            final activeTab = controller.activeTab;
            return BrowserToolbar(
              controller: controller,
              urlController: controller.urlController,
              focusNode: controller.focusNode,
              isDark: isDark,
              isRtl: isRtl,
              isLoading: isLoading,
              progress: progress,
              canGoBack: canGoBack,
              isHomeTab: isHome,
              tabCount: tabCount,
              desktopMode: desktopMode,
              textClr: textClr,
              settings: settings,
              isHttps: isHttps,
              youtubeGrabButton: _buildYoutubeGrabButton(
                context,
                controller,
                activeTab,
                isDark,
              ),
              // FIX(D6): PiP button — only visible when the active tab has a
              // <video> element in its DOM.
              pipButton: (activeTab != null && activeTab.hasVideoElement)
                  ? _buildPipButton(context, controller, activeTab, isDark)
                  : null,
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
                    blockedPopupsCount:
                        controller.blockedPopupsCount(activeTab.id),
                    onReloadTab: () => controller.reload(),
                    // FIX(D8): Wire the element picker to the controller so a
                    // picked element becomes a persistent ad-block rule.
                    onStartElementPicker: () {
                      controller.startElementPicker(activeTab);
                    },
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

        // FIX(P1): Banner rebuilds only when incognito visibility changes.
        Selector<BrowserController, bool>(
          selector: (_, c) =>
              (c.activeTab?.isIncognito ?? false) &&
              !c.incognitoBannerDismissed,
          builder: (context, showBanner, _) {
            if (!showBanner) return const SizedBox.shrink();
            return Container(
              width: double.infinity,
              color: isDark ? const Color(0xFF1E1E2C) : const Color(0xFFE8EAF6),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                    onTap: () => controller.dismissIncognitoBanner(),
                    child: const Icon(Icons.close_rounded, size: 16),
                  ),
                ],
              ),
            );
          },
        ),

        // FIX(P1): Tab strip rebuilds only when the tab list contents change.
        Selector<BrowserController, List<BrowserTab>>(
          shouldRebuild: (a, b) {
            if (a.length != b.length) return true;
            for (var i = 0; i < a.length; i++) {
              if (!identical(a[i], b[i])) return true;
            }
            return false;
          },
          selector: (_, c) => c.tabs,
          builder: (context, _, __) => BrowserTabStrip(
            controller: controller,
            settings: settings,
            isDark: isDark,
            textClr: textClr,
          ),
        ),

        // FIX(P1): Find-in-page panel visibility.
        Selector<BrowserController, bool>(
          selector: (_, c) => c.findPanelVisible,
          builder: (context, visible, _) {
            if (!visible) return const SizedBox.shrink();
            return BrowserFindPanel(controller: controller, settings: settings);
          },
        ),

        // FIX(P1): Reader controls visibility.
        Selector<BrowserController, bool>(
          selector: (_, c) => c.readerControlsVisible,
          builder: (context, visible, _) {
            if (!visible) return const SizedBox.shrink();
            return _ReaderControlsToolbar(
              controller: controller,
              isDark: isDark,
              textClr: textClr,
              isRtl: isRtl,
            );
          },
        ),
      ],
    );
  }

  Widget? _buildYoutubeGrabButton(
    BuildContext context,
    BrowserController controller,
    BrowserTab? activeTab,
    bool isDark,
  ) {
    if (activeTab == null || activeTab.isHome) return null;

    final rawUrl = activeTab.url;
    final lower = rawUrl.toLowerCase().trim();

    // Exclude YouTube home, feeds, subscriptions, explore, and search result list pages
    final isYoutubeHome = lower == 'https://youtube.com' ||
        lower == 'https://youtube.com/' ||
        lower == 'https://www.youtube.com' ||
        lower == 'https://www.youtube.com/' ||
        lower == 'https://m.youtube.com' ||
        lower == 'https://m.youtube.com/' ||
        lower.startsWith('https://youtube.com/feed') ||
        lower.startsWith('https://www.youtube.com/feed') ||
        lower.startsWith('https://m.youtube.com/feed') ||
        lower.startsWith('https://youtube.com/explore') ||
        lower.startsWith('https://www.youtube.com/explore') ||
        lower.startsWith('https://m.youtube.com/explore');

    if (isYoutubeHome) return null;

    final isYtVideoOrPlaylist = YoutubeService.isYoutubeVideoUrl(rawUrl) ||
        YoutubeService.isPlaylistUrl(rawUrl) ||
        (MediaSniffer.isYoutubeHost(rawUrl) &&
            (lower.contains('/watch') ||
                lower.contains('/shorts/') ||
                lower.contains('/playlist') ||
                lower.contains('youtu.be/')));

    final isYt = MediaSniffer.isYoutubeHost(rawUrl) ||
        YoutubeService.isYoutubeUrl(rawUrl);

    final detectedSources =
        controller.mediaSniffer.detectedMediaSources[activeTab.id] ?? [];
    final hasPlaylist =
        controller.mediaSniffer.detectedPlaylistUrls[activeTab.id] != null ||
            YoutubeService.isPlaylistUrl(rawUrl);
    final hasStreams = detectedSources.isNotEmpty;
    final hasGenericDownload =
        controller.mediaSniffer.detectedDownloadUrls[activeTab.id] != null;

    final shouldShow = isYt
        ? (isYtVideoOrPlaylist || hasStreams || hasPlaylist)
        : (hasStreams || hasGenericDownload);

    if (!shouldShow) return null;

    final isYoutubePlaylist = hasPlaylist && isYt;
    final badgeCount = isYoutubePlaylist
        ? (controller.mediaSniffer.detectedPlaylistUrls[activeTab.id] ?? 0)
        : detectedSources.length;

    return YoutubeGrabButton(
      url: rawUrl,
      sourcesCount: detectedSources.length,
      playlistCount: badgeCount,
      isYt: isYt,
      isYoutubePlaylist: isYoutubePlaylist,
      isDark: isDark,
      onPressed: () => _handleGrabButtonPressed(
        context,
        rawUrl: rawUrl,
        isYt: isYt,
        isYoutubePlaylist: isYoutubePlaylist,
        hasStreams: hasStreams,
        hasGenericDownload: hasGenericDownload,
      ),
    );
  }

  // FIX(D6): Picture-in-Picture toolbar button. Shown only when the active tab
  // has a <video> element; tapping it enters PiP via PictureInPictureService.
  Widget _buildPipButton(
    BuildContext context,
    BrowserController controller,
    BrowserTab activeTab,
    bool isDark,
  ) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 30,
        minHeight: 36,
      ),
      icon: Icon(
        Icons.picture_in_picture_alt_rounded,
        size: 19,
        color: isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary,
      ),
      tooltip: L10n.of(context, 'browser_pip_tooltip'),
      onPressed: () async {
        final settings = context.read<SettingsProvider>();
        HapticHelper.triggerHaptic(settings);
        final webController = activeTab.controller;
        if (webController == null) return;
        final success = await PictureInPictureService.enterPiP(webController);
        if (success) return;
        if (context.mounted) {
          ThemedSnackbar.show(
            context,
            message: L10n.of(context, 'browser_pip_unsupported'),
            color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
            icon: Icons.picture_in_picture_alt_rounded,
            isDarkMode: isDark,
          );
        }
      },
    );
  }

  Future<void> _handleGrabButtonPressed(
    BuildContext context, {
    required String rawUrl,
    required bool isYt,
    required bool isYoutubePlaylist,
    required bool hasStreams,
    required bool hasGenericDownload,
  }) async {
    final settings = context.read<SettingsProvider>();
    HapticHelper.triggerHaptic(settings);

    if (isYoutubePlaylist) {
      await YoutubePlaylistSheet.show(context, rawUrl);
    } else if (isYt || hasStreams) {
      final stream = await MediaQualitySheet.show(
        context,
        rawUrl,
      );
      if (stream != null && context.mounted) {
        final title = stream['title'] as String? ?? 'Media Download';
        final ext = stream['ext'] as String? ?? 'mp4';
        final streamUrl = (stream['src'] ?? stream['url'] ?? '') as String;
        final streamSize = (stream['size'] as num?)?.toInt() ?? 0;
        final audioUrl = stream['audioSrc'] as String?;
        final audioSize = (stream['audioSize'] as num?)?.toInt();
        final streamType = stream['type'] as String? ?? 'muxed';
        final thumbnailUrl = stream['thumbnailUrl'] as String?;
        final qualityPreset =
            streamType == 'audio' ? 'audio_only' : stream['quality'] as String?;
        final category = streamType == 'audio' ? 'Audio' : 'Video';
        final fileName = safeFileName('$title.$ext');
        final provider = context.read<DownloadProvider>();
        final settings = context.read<SettingsProvider>();
        final savePath = settings.customDownloadPath ?? '';

        try {
          await provider.addDownload(
            name: fileName,
            url: streamUrl,
            size: streamSize,
            category: category,
            savePath: savePath,
            threadCount: settings.defaultThreadCount,
            downloadPageUrl: rawUrl,
            youtubeQualityPreset: qualityPreset,
            mergedAudioUrl: audioUrl,
            audioSize: audioSize ?? 0,
            thumbnailUrl: thumbnailUrl,
          );
          if (context.mounted) {
            final isDark = settings.isDarkMode;
            if (provider.lastError != null) {
              ThemedSnackbar.show(
                context,
                message: provider.lastError!,
                color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
                icon: Icons.error_outline,
                isDarkMode: isDark,
              );
            } else {
              ThemedSnackbar.show(
                context,
                message:
                    L10n.isRtl(context) ? 'تم بدء التحميل' : 'Download started',
                color: isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
                icon: Icons.check_circle_outline,
                isDarkMode: isDark,
              );
            }
          }
        } catch (e) {
          if (context.mounted) {
            final isDark = settings.isDarkMode;
            ThemedSnackbar.show(
              context,
              message: 'Download failed: $e',
              color: isDark ? AppTheme.neonRed : AppTheme.lightNeonRed,
              icon: Icons.error_outline,
              isDarkMode: isDark,
            );
          }
        }
      }
    } else if (hasGenericDownload) {
      final activeTab = controller.activeTab;
      final directUrl = activeTab != null
          ? controller.mediaSniffer.detectedDownloadUrls[activeTab.id]
          : null;
      if (directUrl != null) {
        controller.downloadCoordinator.promptDownload(context, url: directUrl);
      }
    }
  }
}

/// FIX(P3): Extracted YouTube/download-grab button. Receives only the data it
/// needs (url, source counts, playlist flag) instead of the whole controller.
class YoutubeGrabButton extends StatelessWidget {
  final String url;
  final int sourcesCount;
  final int playlistCount;
  final bool isYt;
  final bool isYoutubePlaylist;
  final bool isDark;
  final VoidCallback onPressed;

  const YoutubeGrabButton({
    super.key,
    required this.url,
    required this.sourcesCount,
    required this.playlistCount,
    required this.isYt,
    required this.isYoutubePlaylist,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final buttonColor = isYt ? const Color(0xFFFF0000) : AppTheme.neonBlue;
    final badgeCount = isYoutubePlaylist ? playlistCount : sourcesCount;

    return Tooltip(
      message: isYt
          ? (isYoutubePlaylist
              ? (L10n.isRtl(context)
                  ? 'تحميل قائمة تشغيل يوتيوب'
                  : 'Download YouTube Playlist')
              : (L10n.isRtl(context)
                  ? 'تحميل فيديو يوتيوب'
                  : 'Download YouTube Video'))
          : (L10n.isRtl(context)
              ? 'تحميل الوسائط المكتشفة'
              : 'Download Detected Media'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: buttonColor.withValues(alpha: isDark ? 0.18 : 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: buttonColor.withValues(alpha: 0.45),
                width: 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isYt ? Icons.play_arrow_rounded : Icons.download_rounded,
                  size: 16,
                  color: buttonColor,
                ),
                if (badgeCount > 0) ...[
                  const SizedBox(width: 2),
                  Text(
                    badgeCount > 99 ? '99+' : '$badgeCount',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: buttonColor,
                    ),
                  ),
                ],
              ],
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
              final newSize =
                  (controller.readerFontSize - 2.0).clamp(12.0, 28.0);
              controller.setReaderFontSize(newSize);
            },
            tooltip: 'Decrease font size',
          ),
          Text(
            '${controller.readerFontSize.round()}px',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold, color: textClr),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase_rounded, size: 18),
            onPressed: () {
              final newSize =
                  (controller.readerFontSize + 2.0).clamp(12.0, 28.0);
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
            color: isSelected
                ? AppTheme.neonBlue
                : Colors.grey.withValues(alpha: 0.4),
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
