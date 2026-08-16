part of 'browser_screen.dart';

class _BrowserTabView extends StatefulWidget {
  final BrowserTab tab;
  final _BrowserScreenStateBase state;
  final SettingsProvider settings;

  const _BrowserTabView({
    required this.tab,
    required this.state,
    required this.settings,
  });

  @override
  State<_BrowserTabView> createState() => _BrowserTabViewState();
}

class _BrowserTabViewState extends State<_BrowserTabView> {
  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final isDark = settings.isDarkMode;
    final tab = widget.tab;

    return RefreshIndicator(
      color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
      onRefresh: () async {
        tab.hasCrashed = false;
        await widget.state._refreshTabForPull(tab);
      },
      child: tab.hasCrashed
          ? AnimatedOpacity(
              opacity: 1.0,
              duration: AppTheme.motionBase,
              child: Container(
                color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.elasticOut,
                        builder: (context, value, child) {
                          final offset = sin(value * pi * 4) * (1 - value) * 4;
                          return Transform.translate(
                              offset: Offset(offset, 0), child: child);
                        },
                        child: const Icon(Icons.error_outline_rounded,
                            size: 54, color: Colors.orangeAccent),
                      ),
                      const SizedBox(height: 12),
                      Text('This tab crashed unexpectedly',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87)),
                      const SizedBox(height: 8),
                      Text(tab.url,
                          style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white54 : Colors.black54),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            foregroundColor: Colors.white),
                        onPressed: () {
                          widget.state._safeReloadTab(tab);
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Reload Tab'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : tab.hasError
              ? Container(
                  color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.wifi_off_rounded,
                            size: 48, color: Colors.grey),
                        const SizedBox(height: 16),
                        Text(
                          'Failed to load page',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            tab.errorDescription ?? 'Unknown error',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white54 : Colors.black54,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark
                                ? AppTheme.neonBlue
                                : AppTheme.lightNeonBlue,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            widget.state.setState(() {
                              tab.hasError = false;
                            });
                            widget.state._safeReloadTab(tab);
                          },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    RepaintBoundary(
                      key: ValueKey('webview_${tab.id}'),
                      // FIX-P2-04: WebView error boundary & layout
                      child: InAppWebView(
                        findInteractionController:
                            tab.findInteractionController,
                        initialUrlRequest: tab.url.isEmpty
                            ? null
                            : URLRequest(url: WebUri(tab.url)),
                        onWebViewCreated: (controller) {
                          widget.state._configureController(tab, controller);
                          widget.state._hideWebViewFingerprints(tab);
                        },
                        initialUserScripts: UnmodifiableListView<UserScript>([
                          UserScript(
                            source: '''
                  window.XDM_LongPress = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XDM_LongPress', msg); } };
                  window.XDM_Popups = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XDM_Popups', msg); } };
                  window.XdmPickerChannel = { postMessage: function(msg) { window.flutter_inappwebview.callHandler('XdmPickerChannel', msg); } };
                  ${ScriptInjector.kLongPressScript}
                ''',
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                          UserScript(
                            source: AdBlockerService.youtubeEarlyJs,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                          UserScript(
                            source: widget.state._adBlocker.antiDetectJs,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                          UserScript(
                            source:
                                'window.__xdmDynamicAdDomains = ${widget.state._adBlocker.dynamicDomainsJson};\n${widget.state._adBlocker.earlyJs}',
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                        ]),
                        initialSettings: InAppWebViewSettings(
                          useShouldOverrideUrlLoading: true,
                          useOnDownloadStart: true,
                          useHybridComposition: true,
                          useShouldInterceptRequest: true,
                          transparentBackground: true,
                          allowsInlineMediaPlayback: true,
                          mediaPlaybackRequiresUserGesture: false,
                          javaScriptEnabled: true,
                          domStorageEnabled: true,
                          databaseEnabled: true,
                          thirdPartyCookiesEnabled: true,
                          cacheEnabled: true,
                          forceDark: widget.state._effectiveForceDark(settings)
                              ? ForceDark.ON
                              : ForceDark.OFF,
                          supportZoom:
                              settings.desktopMode || settings.pinchToZoom,
                          contentBlockers:
                              widget.state._adBlocker.contentBlockers,
                          incognito: tab.isIncognito,
                          supportMultipleWindows: true,
                          javaScriptCanOpenWindowsAutomatically: true,
                        ),
                        onReceivedServerTrustAuthRequest:
                            (controller, challenge) async {
                          return ServerTrustAuthResponse(
                              action: ServerTrustAuthResponseAction.CANCEL);
                        },
                        onCreateWindow: (controller, createWindowAction) async {
                          final reqUrl = createWindowAction.request.url;
                          if (reqUrl != null) {
                            widget.state._handlePopupMessageForTab(tab,
                                BrowserJsMessage(message: reqUrl.toString()));
                          }
                          return false;
                        },
                        onConsoleMessage: (controller, consoleMessage) {
                          final msg = consoleMessage.message;
                          if (msg.contains('recaptcha') ||
                              msg.contains("reading 'e3'")) {
                            return;
                          }
                          widget.state._log.fine(
                              '[WebView Console] ${consoleMessage.messageLevel}: $msg');
                        },
                        onLongPressHitTestResult:
                            (controller, hitTestResult) async {
                          widget.state.triggerHaptic(settings);
                          var targetUrl = hitTestResult.extra;
                          String typeOverride = '';
                          if (targetUrl == null || targetUrl.trim().isEmpty) {
                            try {
                              final jsUrl = await controller.evaluateJavascript(
                                source: widget.state._longPressTargetFallbackJs,
                              );
                              final resolved = widget.state
                                  ._parseLongPressTarget(jsUrl?.toString());
                              if (resolved != null) {
                                targetUrl = resolved.$1;
                                typeOverride = resolved.$2;
                              }
                            } catch (e, st) {
                              LoggingService.logger('BrowserTabView')
                                  .warning('Operation failed', e, st);
                            }
                          }
                          if (targetUrl != null &&
                              targetUrl.trim().isNotEmpty) {
                            if (!mounted || !context.mounted) {
                              return;
                            }
                            String type =
                                typeOverride.isNotEmpty ? typeOverride : 'link';
                            final hType = hitTestResult.type;
                            if (hType ==
                                    InAppWebViewHitTestResultType.IMAGE_TYPE ||
                                hType ==
                                    InAppWebViewHitTestResultType
                                        .SRC_IMAGE_ANCHOR_TYPE) {
                              type = 'image';
                            }
                            if (!mounted || !context.mounted) {
                              return;
                            }
                            widget.state._showLongPressSheet(
                                context, targetUrl.trim(), type,
                                tabId: tab.id);
                          }
                        },
                        gestureRecognizers: const <Factory<
                            OneSequenceGestureRecognizer>>{},
                        pullToRefreshController: tab.pullToRefreshController,
                        onScrollChanged: (controller, x, y) {
                          if (mounted &&
                              widget.state._currentTabIndex >= 0 &&
                              widget.state._currentTabIndex <
                                  widget.state._tabs.length &&
                              widget.state._tabs[widget.state._currentTabIndex]
                                      .id ==
                                  tab.id) {
                            widget.state._handleScroll(y.toDouble());
                          }
                        },
                        onLoadStart: (controller, url) {
                          widget.state._onPageStart(tab, url?.toString() ?? '');
                        },
                        onLoadStop: (controller, url) async {
                          widget.state._onPageStop(tab, url?.toString() ?? '');
                          if (url == null) {
                            return;
                          }
                          final res =
                              await widget.state._redirectGuard.extractFromPage(
                            tabId: tab.id,
                            controller: controller,
                          );
                          switch (res.decision) {
                            case RedirectDecision.autoFollow:
                              await Future.delayed(
                                  const Duration(milliseconds: 400));
                              if (tab.isDisposed || !mounted) {
                                break;
                              }
                              try {
                                await controller.loadUrl(
                                    urlRequest: URLRequest(
                                        url: WebUri(res.targetUrl!)));
                              } catch (e) {
                                widget.state._log.warning(
                                    '[Browser] autoFollow loadUrl failed: $e');
                              }
                              break;
                            case RedirectDecision.promptUser:
                              if (context.mounted && !tab.isDisposed) {
                                RedirectSheet.show(
                                  context,
                                  candidates: res.candidates,
                                  onSelected: (u) {
                                    if (tab.isDisposed || !mounted) return;
                                    try {
                                      controller.loadUrl(
                                          urlRequest:
                                              URLRequest(url: WebUri(u)));
                                    } catch (e) {
                                      widget.state._log.warning(
                                          '[Browser] promptUser loadUrl failed: $e');
                                    }
                                  },
                                );
                              }
                              break;
                            case RedirectDecision.block:
                            case RedirectDecision.ignore:
                              break;
                          }
                        },
                        onProgressChanged: (controller, progress) {
                          if (progress == 0 ||
                              progress == 100 ||
                              (progress - tab.lastRenderedProgress).abs() >=
                                  2) {
                            widget.state.setState(() {
                              tab.lastRenderedProgress = progress;
                              tab.progress = progress / 100;
                            });
                          }
                        },
                        onUpdateVisitedHistory: (controller, url, isReload) {
                          if (url != null) {
                            widget.state._onUrlChange(tab, url.toString());
                          }
                        },
                        onDownloadStartRequest:
                            (controller, downloadStartRequest) async {
                          final url = downloadStartRequest.url.toString();
                          widget.state._log
                              .info('[Browser] onDownloadStartRequest: $url');
                          widget.state._markUrlAsDownloaded(url);
                          final isDark =
                              context.read<SettingsProvider>().isDarkMode;
                          final result = await widget.state._interceptor
                              .startDirectDownload(
                            url,
                            suggestedName:
                                downloadStartRequest.suggestedFilename,
                            mimeType: downloadStartRequest.mimeType,
                            contentLength: downloadStartRequest.contentLength,
                            contentDisposition:
                                downloadStartRequest.contentDisposition,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          if (result.status == InterceptDownloadStatus.queued) {
                            final filename =
                                downloadStartRequest.suggestedFilename ??
                                    fileNameFromUrl(url);
                            ThemedSnackbar.show(
                              context,
                              message: 'Download started: $filename',
                              icon: Icons.download_done_rounded,
                              color: AppTheme.neonGreen,
                              isDarkMode: isDark,
                            );
                          } else if (result.status ==
                              InterceptDownloadStatus.alreadyInProgress) {
                            ThemedSnackbar.show(
                              context,
                              message: 'Download already in progress',
                              icon: Icons.info_outline,
                              color: AppTheme.neonAmber,
                              isDarkMode: isDark,
                            );
                          }
                        },
                        onReceivedError: (controller, request, error) async {
                          widget.state._log.warning(
                              '[Browser] WebResourceError on tab ${tab.id}: ${error.description}');
                          final errUrl = request.url.toString();
                          if (errUrl.startsWith('magnet:') ||
                              isMagnetUrl(errUrl) ||
                              error.description
                                  .contains('ERR_UNKNOWN_URL_SCHEME')) {
                            widget.state._log.info(
                                '[Browser] WebResourceError handled for magnet link: $errUrl');
                            controller.stopLoading();
                            if (await controller.canGoBack()) {
                              await controller.goBack();
                            }
                            if (mounted) {
                              widget.state.setState(() {
                                tab.isLoading = false;
                              });
                            }
                            return;
                          }
                          if (mounted && request.isForMainFrame == true) {
                            widget.state.setState(() {
                              tab.isLoading = false;
                            });
                          }
                        },
                        onRenderProcessGone: (controller, detail) async {
                          widget.state._log.warning(
                              '[Browser] Render process gone on tab ${tab.id}: didCrash=${detail.didCrash}');
                          if (mounted) {
                            widget.state.setState(() {
                              tab.isLoading = false;
                              tab.hasCrashed = true;
                              tab.controller = null;
                            });
                          }
                        },
                        shouldInterceptRequest: (controller, request) async {
                          // Never block main-frame requests
                          if (request.isForMainFrame == true) {
                            return null;
                          }

                          final requestHost = request.url.host.toLowerCase();

                          // Instant fast-path: Never block YouTube, Google, gstatic, or core media infrastructure
                          const whitelistedDomains = [
                            'youtube.com',
                            'youtu.be',
                            'ytimg.com',
                            'googlesyndication.com',
                            'googlevideo.com',
                            'ggpht.com',
                            'googleapis.com',
                            'google.com',
                            'gstatic.com',
                          ];
                          bool isWhitelisted = false;
                          for (final d in whitelistedDomains) {
                            if (requestHost == d ||
                                requestHost.endsWith('.$d')) {
                              isWhitelisted = true;
                              break;
                            }
                          }
                          if (isWhitelisted) {
                            return null;
                          }

                          // Never block same-origin requests (requests to the current site's own domain or subdomains)
                          final pageHost = tab.host;
                          if (pageHost.isNotEmpty &&
                              (requestHost == pageHost ||
                                  requestHost.endsWith('.$pageHost') ||
                                  (requestHost.contains('.') &&
                                      pageHost.endsWith('.$requestHost')))) {
                            return null;
                          }

                          final url = request.url.toString();
                          if (widget.state._adBlocker.shouldBlock(url)) {
                            widget.state._adBlocker.recordBlocked(url);
                            final count =
                                (widget.state._blockedAdsPerTab[tab.id] ?? 0) +
                                    1;
                            widget.state._blockedAdsPerTab[tab.id] = count;
                            widget.state._evictTrackingMapsIfNeeded();

                            final notifier =
                                widget.state._blockedAdsNotifiers[tab.id];
                            if (notifier != null) {
                              notifier.value = count;
                            }

                            return WebResourceResponse(
                              contentType: 'text/plain',
                              contentEncoding: 'utf-8',
                              statusCode: 204,
                              reasonPhrase: 'Blocked',
                              data: Uint8List(0),
                            );
                          }
                          return null;
                        },
                        shouldOverrideUrlLoading:
                            (controller, navigationAction) async {
                          final url =
                              navigationAction.request.url?.toString() ?? '';
                          if (url.isEmpty) {
                            return NavigationActionPolicy.ALLOW;
                          }
                          if ((widget
                                  .state._navigatingBackForwardTabIds[tab.id] ??
                              false)) {
                            return NavigationActionPolicy.ALLOW;
                          }
                          if (widget.state._recentDownloadUrls.contains(url)) {
                            widget.state._log.info(
                                '[Browser] shouldOverrideUrlLoading: ignoring $url (already downloading)');
                            return NavigationActionPolicy.CANCEL;
                          }

                          final res =
                              await widget.state._redirectGuard.evaluate(
                            tabId: tab.id,
                            navigatingTo: url,
                          );
                          if (res.decision == RedirectDecision.block) {
                            return NavigationActionPolicy.CANCEL;
                          }

                          // 0. Ad-blocker: cancel navigation-level ad redirects
                          // Only block sub-frame navigations (ads redirect in iframes/popups)
                          // Never block main-frame navigations so user can still browse
                          if (navigationAction.isForMainFrame != true &&
                              widget.state._adBlocker.shouldBlock(url)) {
                            widget.state._adBlocker.recordBlocked(url);
                            return NavigationActionPolicy.CANCEL;
                          }

                          // 1. Magnet link check
                          if (url.startsWith('magnet:') || isMagnetUrl(url)) {
                            widget.state._log.info(
                                '[Browser] Intercepted magnet link in navigation: $url');
                            if (context.mounted) {
                              widget.state._showInterceptionSheet(context, url);
                            }
                            return NavigationActionPolicy.CANCEL;
                          }

                          // 2. HTTPS-only upgrade check
                          if (navigationAction.isForMainFrame == true &&
                              settings.httpsOnly &&
                              url.startsWith('http://')) {
                            final upgraded =
                                url.replaceFirst('http://', 'https://');
                            widget.state._log.warning(
                                '[Browser] HTTPS-only: upgrading $url -> $upgraded');
                            controller.loadUrl(
                                urlRequest: URLRequest(url: WebUri(upgraded)));
                            return NavigationActionPolicy.CANCEL;
                          }

                          // 2b. UX 3.10: Open in external app (user-initiated main-frame only).
                          if (navigationAction.isForMainFrame == true &&
                              navigationAction.hasGesture == true &&
                              await widget.state._maybeOpenInApp(url)) {
                            return NavigationActionPolicy.CANCEL;
                          }

                          // 3. Bypass check — user tapped "Continue browsing" on the
                          // interception sheet. The URL was marked via addBypass; a
                          // one-shot consume lets it load without re-interception.
                          if (widget.state._interceptor.consumeBypass(url)) {
                            widget.state._log.info(
                                '[Browser] Bypassing download interception for: $url');
                            return NavigationActionPolicy.ALLOW;
                          }
                          final classification = await PageIntentClassifier
                              .instance
                              .classifyWithContextAsync(
                            currentUrl: tab.url,
                            targetUrl: url,
                            interceptor: widget.state._interceptor,
                            isUserInitiated: navigationAction.isForMainFrame,
                            isFromClick:
                                navigationAction.request.method == 'GET',
                          );

                          widget.state._log.info(
                              '[Browser] Classification for $url: ${classification.action.name} (intent: ${classification.intent.name}, confidence: ${classification.confidence})');

                          switch (classification.action) {
                            case PageAction.block:
                              AdBlockerService.instance
                                  .recordBlockedRequest(url);
                              widget.state._log
                                  .warning('[AdBlocker] Blocked: $url');
                              return NavigationActionPolicy.CANCEL;

                            case PageAction.openNewTab:
                            case PageAction.openNewTabWithWarning:
                            case PageAction.openNewTabWithDownloadSuggestion:
                              // Browser redirects (e.g. http→https, www→non-www)
                              // must navigate inside the current tab, not open a
                              // new one — guard with isRedirect.
                              if (navigationAction.isRedirect == true) {
                                return NavigationActionPolicy.ALLOW;
                              }
                              // User-triggered tap → open in foreground.
                              if (navigationAction.hasGesture == true) {
                                widget.state._openInNewTab(url,
                                    isIncognito: tab.isIncognito,
                                    switchToTab: true,
                                    origin: TabOrigin.userDirect);
                                return NavigationActionPolicy.CANCEL;
                              }
                              // Auto/ad navigation → background tab.
                              widget.state._evictStaleAdTabs();
                              widget.state._openInNewTab(url,
                                  isIncognito: tab.isIncognito,
                                  switchToTab: false,
                                  origin: TabOrigin.adOrPopup);
                              if (context.mounted) {
                                final bgSettings =
                                    context.read<SettingsProvider>();
                                final bgDark = bgSettings.isDarkMode;
                                final bgRtl = L10n.isRtl(context);
                                ThemedSnackbar.show(
                                  context,
                                  message: bgRtl
                                      ? 'تم فتح علامة تبويب في الخلفية'
                                      : 'Opened in background tab',
                                  color: bgDark
                                      ? AppTheme.neonBlue
                                      : AppTheme.lightNeonBlue,
                                  icon: Icons.tab_rounded,
                                  isDarkMode: bgDark,
                                );
                              }
                              if (classification.action ==
                                  PageAction.openNewTabWithDownloadSuggestion) {
                                widget.state
                                    ._suggestDownload(url, classification);
                              }
                              if (classification.action ==
                                  PageAction.openNewTabWithWarning) {
                                if (context.mounted) {
                                  widget.state._showAdWarning(context, url);
                                }
                              }
                              return NavigationActionPolicy.CANCEL;

                            case PageAction.openBackgroundTab:
                              widget.state._openInBackgroundTab(url,
                                  isIncognito: tab.isIncognito);
                              return NavigationActionPolicy.CANCEL;

                            case PageAction.directDownload:
                              if (context.mounted) {
                                widget.state
                                    ._showInterceptionSheet(context, url);
                              }
                              return NavigationActionPolicy.CANCEL;

                            case PageAction.openSameTab:
                              if (widget.state._interceptor.shouldIntercept(
                                  tabUrl: tab.url, requestUrl: url)) {
                                widget.state.setState(() {
                                  widget.state._detectedDownloadUrls[tab.id] =
                                      url;
                                });
                                if (context.mounted) {
                                  widget.state
                                      ._showInterceptionSheet(context, url);
                                }
                                return NavigationActionPolicy.CANCEL;
                              }
                              return NavigationActionPolicy.ALLOW;
                          }
                        },
                      ),
                    ),
                    // E13: Tab Suspension/Resume Visual Feedback
                    if (widget.state._restoringTabId == tab.id)
                      Positioned.fill(
                        child: AnimatedOpacity(
                          opacity: 1.0,
                          duration: AppTheme.motionBase,
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.7),
                            child: const Center(
                                child: Text('Restoring tab...',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 16))),
                          ),
                        ),
                      ),
                    // E5: Media Sniffer Detection Feedback
                    ListenableBuilder(
                      listenable: widget.state._sniffer,
                      builder: (context, child) {
                        final detectedSources =
                            widget.state._sniffer.detectedMediaSources[tab.id];
                        if (detectedSources == null ||
                            detectedSources.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Positioned(
                          top: 16,
                          right: 16,
                          child: AnimatedScale(
                            scale: 1.0,
                            duration: AppTheme.motionBase,
                            child: AnimatedOpacity(
                              opacity: 1.0,
                              duration: AppTheme.motionBase,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppTheme.neonBlue
                                            .withValues(alpha: 0.3)),
                                  ),
                                  const CircleAvatar(
                                    backgroundColor: AppTheme.neonBlue,
                                    radius: 10,
                                    child: Icon(Icons.download_rounded,
                                        size: 12, color: Colors.white),
                                  ),
                                  Positioned(
                                    top: -4,
                                    right: -4,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle),
                                      constraints: const BoxConstraints(
                                          minWidth: 14, minHeight: 14),
                                      child: Text('${detectedSources.length}',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    // E6: Element Picker Mode Indicator
                    if (widget.state._isPickerModeActive)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Material(
                          color: Colors.blue,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 8.0, horizontal: 16.0),
                            child: Row(
                              children: [
                                const Icon(Icons.touch_app_rounded,
                                    color: Colors.white, size: 16),
                                const SizedBox(width: 8),
                                const Expanded(
                                    child: Text(
                                        'Element Picker Mode — Tap an element to block it',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12))),
                                TextButton(
                                    onPressed: () => widget.state.setState(() =>
                                        widget.state._isPickerModeActive =
                                            false),
                                    child: const Text('Done',
                                        style: TextStyle(color: Colors.white))),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (widget.state._isPickerModeActive)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: true,
                          child: Container(
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Colors.blue.withValues(alpha: 0.5),
                                      width: 2))),
                        ),
                      ),
                    // E12: Tab Timeout Visual Feedback
                    if (tab.isTimedOut && tab.isLoading)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: AnimatedOpacity(
                          opacity: 1.0,
                          duration: AppTheme.motionBase,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            color: Colors.orange.withValues(alpha: 0.9),
                            child: Row(
                              children: [
                                TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0.8, end: 1.2),
                                  duration: const Duration(milliseconds: 800),
                                  builder: (context, value, child) =>
                                      Transform.scale(
                                          scale: value, child: child),
                                  child: const Icon(Icons.warning_amber_rounded,
                                      size: 16, color: Colors.white),
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text('Page load taking long...',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold)),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    tab.controller?.evaluateJavascript(
                                        source: 'window.stop();');
                                    widget.state.setState(() {
                                      tab.isLoading = false;
                                      tab.isTimedOut = false;
                                    });
                                  },
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6),
                                      child: Text(
                                          L10n.of(context, 'stop_loading'),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12))),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    widget.state._safeReloadTab(tab);
                                    tab.isTimedOut = false;
                                  },
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6),
                                      child: Text(
                                          L10n.of(context, 'reload_page'),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12))),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
