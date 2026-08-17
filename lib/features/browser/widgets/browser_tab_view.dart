import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_theme.dart';
import '../../../core/services/redirect_guard.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/url_utils.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/browser_tab.dart';
import '../services/browser_controller.dart';
import '../services/download_interceptor.dart';
import '../services/long_press_parser.dart';
import 'link_options_sheet.dart';

class BrowserTabView extends StatefulWidget {
  final BrowserTab tab;
  final BrowserController controller;
  final SettingsProvider settings;

  const BrowserTabView({
    super.key,
    required this.tab,
    required this.controller,
    required this.settings,
  });

  @override
  State<BrowserTabView> createState() => _BrowserTabViewState();
}

class _BrowserTabViewState extends State<BrowserTabView> with HapticHelper {
  static final _log = Logger('BrowserTabView');
  bool _attemptedSilentCrashReload = false;

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final settings = widget.settings;
    final isDark = settings.isDarkMode;
    final accent = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;

    if (tab.isSuspended) {
      return Container(
        color: isDark ? AppTheme.surface : AppTheme.lightSurface,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.pause_circle_outline_rounded,
                size: 56,
                color: textClr.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 12),
              Text(
                L10n.of(context, 'browser_tab_paused'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textClr,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                tab.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: textClr.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  HapticHelper.triggerHaptic(settings);
                  widget.controller.resumeTab(tab);
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text(L10n.of(context, 'browser_tap_to_resume')),
              ),
            ],
          ),
        ),
      );
    }

    final webView = InAppWebView(
      key: ValueKey('webview_${tab.id}'),
      initialUrlRequest: tab.url.isNotEmpty && tab.url != BrowserTab.canonicalBlankUrl
          ? URLRequest(url: WebUri(tab.url))
          : null,
      pullToRefreshController: tab.pullToRefreshController,
      initialSettings: InAppWebViewSettings(
        useShouldOverrideUrlLoading: true,
        useShouldInterceptRequest: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        javaScriptEnabled: true,
        transparentBackground: false,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        isInspectable: kDebugMode,
        forceDark: settings.isDarkMode ? ForceDark.ON : ForceDark.OFF,
      ),
      onWebViewCreated: (controller) {
        tab.controller = controller;
        _setupJsHandlers(controller);
      },
      onLoadStart: (controller, url) {
        widget.controller.handlePageLoadStart(tab, url?.toString());
        if (mounted) setState(() {});
      },
      onLoadStop: (controller, url) async {
        widget.controller.handlePageLoadStop(tab, url?.toString());
        if (mounted) setState(() {});
      },
      onProgressChanged: (controller, progress) {
        // P1: Throttle progress updates to >= 5% changes or 0/100
        if (progress == 0 || progress == 100 || (progress - tab.lastRenderedProgress).abs() >= 5) {
          tab.lastRenderedProgress = progress;
          tab.progress = progress / 100.0;
        }
      },
      onUpdateVisitedHistory: (controller, url, isReload) {
        if (url != null) {
          tab.updateUrl(url.toString());
          widget.controller.syncUrlController();
          widget.controller.updateNavState();
        }
      },
      onDownloadStartRequest: (controller, downloadStartRequest) async {
        final url = downloadStartRequest.url.toString();
        final res = await widget.controller.downloadInterceptor.startDirectDownload(
          url,
          suggestedName: downloadStartRequest.suggestedFilename,
          mimeType: downloadStartRequest.mimeType,
          contentLength: downloadStartRequest.contentLength,
          contentDisposition: downloadStartRequest.contentDisposition,
        );
        if (!mounted || !context.mounted) return;
        if (res.status == InterceptDownloadStatus.queued) {
          ThemedSnackbar.show(
            context,
            message: 'Download started: ${downloadStartRequest.suggestedFilename ?? fileNameFromUrl(url)}',
            icon: Icons.download_done_rounded,
            color: AppTheme.neonGreen,
            isDarkMode: settings.isDarkMode,
          );
        }
      },
      onReceivedError: (controller, request, error) async {
        final errUrl = request.url.toString();
        final scheme = Uri.tryParse(errUrl)?.scheme.toLowerCase() ?? '';
        // B12: Do not use localized error description string matching
        if (scheme == 'magnet' || scheme == 'intent' || scheme == 'tg' || scheme == 'whatsapp') {
          controller.stopLoading();
          if (await controller.canGoBack()) {
            await controller.goBack();
          }
          try {
            await launchUrl(Uri.parse(errUrl), mode: LaunchMode.externalApplication);
          } catch (_) {}
          tab.isLoading = false;
          if (mounted) setState(() {});
          return;
        }

        if (request.isForMainFrame == true) {
          widget.controller.handlePageLoadError(tab, error.description);
          if (mounted) setState(() {});
        }
      },
      onRenderProcessGone: (controller, detail) async {
        _log.warning('Render process gone on tab ${tab.id}: didCrash=${detail.didCrash}');
        if (!_attemptedSilentCrashReload) {
          _attemptedSilentCrashReload = true;
          try {
            await controller.reload();
            return;
          } catch (_) {}
        }
        widget.controller.handleTabCrash(tab);
        if (mounted) setState(() {});
      },
      shouldInterceptRequest: (controller, request) async {
        if (request.isForMainFrame == true) return null;

        final requestHost = request.url.host.toLowerCase();
        final pageHost = tab.host.toLowerCase();

        // FIX-B29: Whitelist core infrastructure, but restrict google ad domains to Google/YouTube page hosts
        final isYouTubeOrGoogleHost = pageHost.endsWith('youtube.com') ||
            pageHost.endsWith('youtu.be') ||
            pageHost.endsWith('google.com');

        if (isYouTubeOrGoogleHost) {
          const ytGoogleDomains = [
            'youtube.com', 'youtu.be', 'ytimg.com', 'googlevideo.com',
            'googlesyndication.com', 'ggpht.com', 'googleapis.com', 'google.com', 'gstatic.com'
          ];
          for (final d in ytGoogleDomains) {
            if (requestHost == d || requestHost.endsWith('.$d')) return null;
          }
        } else {
          // General whitelist for core CDN/fonts
          const generalWhitelisted = ['gstatic.com', 'googleapis.com', 'cloudflare.com'];
          for (final d in generalWhitelisted) {
            if (requestHost == d || requestHost.endsWith('.$d')) return null;
          }
        }

        // Never block same-origin requests
        if (pageHost.isNotEmpty && (requestHost == pageHost || requestHost.endsWith('.$pageHost'))) {
          return null;
        }

        final url = request.url.toString();
        if (widget.controller.adBlocker.shouldBlock(url)) {
          widget.controller.recordBlockedAd(tab.id, url);

          // FIX-B30: Return standard 404 response
          return WebResourceResponse(
            contentType: 'text/plain',
            contentEncoding: 'utf-8',
            statusCode: 404,
            reasonPhrase: 'Blocked by AdBlocker',
            data: Uint8List(0),
          );
        }

        return null;
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url?.toString() ?? '';
        if (url.isEmpty || (widget.controller.navigatingBackForwardTabIds[tab.id] ?? false)) {
          return NavigationActionPolicy.ALLOW;
        }

        // Check redirect guard
        final res = await widget.controller.redirectGuard.evaluate(
          tabId: tab.id,
          navigatingTo: url,
        );
        if (res.decision == RedirectDecision.block) {
          return NavigationActionPolicy.CANCEL;
        }

        // Scheme check for external apps
        final uri = Uri.tryParse(url);
        final scheme = uri?.scheme.toLowerCase() ?? '';
        if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https' && scheme != 'about') {
          try {
            await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            return NavigationActionPolicy.CANCEL;
          } catch (_) {}
        }

        // Ad-block navigation check
        if (widget.controller.adBlocker.shouldBlock(url)) {
          widget.controller.recordBlockedAd(tab.id, url);
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
    );

    return Stack(
      children: [
        webView,
        if (tab.hasCrashed)
          Positioned.fill(
            child: Container(
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 54, color: Colors.orangeAccent),
                    const SizedBox(height: 12),
                    Text(
                      'This tab crashed unexpectedly',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textClr,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tab.url,
                      style: TextStyle(fontSize: 12, color: textClr.withValues(alpha: 0.6)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        tab.hasCrashed = false;
                        tab.isLoading = true;
                        if (mounted) setState(() {});
                        widget.controller.reload();
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Reload Tab'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (tab.hasError)
          Positioned.fill(
            child: Container(
              color: isDark ? AppTheme.surface : AppTheme.lightSurface,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.wifi_off_rounded, size: 48, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load page',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textClr,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        tab.errorDescription ?? 'Unknown error',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: textClr.withValues(alpha: 0.6)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        tab.hasError = false;
                        tab.errorDescription = null;
                        tab.isLoading = true;
                        if (mounted) setState(() {});
                        widget.controller.reload();
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (tab.isTimedOut && !tab.isLoading && !tab.hasCrashed && !tab.hasError)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: AppTheme.neonAmber.withValues(alpha: 0.95),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.timer_off_rounded, size: 16, color: Colors.black87),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Page load timed out',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => widget.controller.reload(),
                    child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _setupJsHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'XDM_Autofill',
      callback: (args) {
        if (args.isNotEmpty && args.first is Map) {
          widget.controller.handleAutofillMessage(Map<String, dynamic>.from(args.first as Map));
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'XDM_LongPress',
      callback: (args) {
        if (args.isNotEmpty) {
          _handleLongPress(args.first.toString());
        }
      },
    );
  }

  void _handleLongPress(String rawJson) {
    try {
      // FIX-B26: Safe quote stripping and JSON parsing
      String clean = rawJson.trim();
      if (clean.length >= 2 && clean.startsWith('"') && clean.endsWith('"')) {
        try {
          clean = jsonDecode(clean).toString();
        } catch (_) {
          clean = clean.substring(1, clean.length - 1);
        }
      }
      final payload = LongPressPayload.tryParse(clean);
      if (payload != null && payload.url.isNotEmpty) {
        HapticHelper.triggerHaptic(widget.settings);
        LinkOptionsSheet.show(
          context,
          payload.url,
          onOpen: () => widget.controller.navigateToUrl(payload.url),
          onOpenInNewTab: () => widget.controller.openInNewTab(payload.url, switchTo: true),
          onOpenInBackground: () => widget.controller.openInNewTab(payload.url, switchTo: false),
          onOpenInIncognito: () => widget.controller.openInNewTab(payload.url, isIncognito: true),
        );
      }
    } catch (_) {}
  }

  Color get textClr => widget.settings.isDarkMode ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
}
