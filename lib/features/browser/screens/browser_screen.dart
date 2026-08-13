import 'browser_settings_screen.dart';
import '../widgets/shortcuts_grid_widget.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';
import '../../../core/app_theme.dart';
import '../../../core/services/database/app_database.dart';
import '../../../core/services/database_service.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/user_script_manager.dart' hide UserScript;
import '../../../core/services/youtube_service.dart';
import '../../../core/utils/file_opener.dart';
import '../../../core/utils/haptic_helper.dart';
import '../../../core/utils/localization.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/utils/url_utils.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../shared/mixins/pausable_loop_animation.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/neon_glow_button.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/widgets/add_download_dialog.dart';
import '../../add_download/widgets/youtube_playlist_sheet.dart';
import '../../add_download/widgets/media_quality_sheet.dart';
import '../../downloads/models/download_task.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import '../models/bookmark.dart';
import '../models/browser_tab.dart';
import '../services/fingerprint_manager.dart';
import '../services/script_injector.dart';
import '../services/inactivity_watchdog.dart';
import '../services/browser_detector.dart';
import '../services/ad_blocker_delegate.dart';
import '../services/ad_blocker_service.dart';
import '../services/download_interceptor.dart';
import '../services/element_picker_service.dart';
import '../services/history_manager.dart';
import '../services/long_press_parser.dart';
import '../services/media_sniffer.dart';
import '../services/reader_mode_service.dart';
import '../services/tab_manager.dart';
import '../../../core/services/redirect_guard.dart';
import '../services/page_intent_classifier.dart';
import '../services/site_settings_store.dart';
import '../services/search_engine_config.dart';
import '../screens/script_manager_screen.dart';
import '../widgets/bookmark_manager_screen.dart';
import '../widgets/browser_download_sheet.dart';
import '../widgets/browser_history_sheet.dart';
import '../widgets/browser_home_page.dart';
import '../widgets/link_options_sheet.dart';
import '../widgets/redirect_sheet.dart';
import '../widgets/smart_url_bar.dart';
import '../widgets/browser_shield_sheet.dart';
import 'package:logging/logging.dart';

part 'browser_screen_base.dart';
part 'browser_screen_shortcuts.dart';
part 'browser_screen_tabs.dart';
part 'browser_screen_webview.dart';
part 'browser_screen_popups_ads.dart';
part 'browser_screen_navigation_menu.dart';
part 'browser_screen_media_downloads.dart';
part 'browser_screen_dashboard.dart';
part 'browser_screen_lifecycle.dart';
part 'browser_screen_build.dart';
part 'browser_screen_indicators.dart';
part 'browser_screen_radar_signal.dart';
part 'browser_screen_misc_widgets.dart';
part 'browser_tab_view.dart';

class BrowserJsMessage {
  final String message;
  const BrowserJsMessage({required this.message});
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

/// The concrete state class. All of its actual fields and methods live in
/// the `part` files above, grouped by feature area and combined here via
/// mixins so this file stays short and the class remains one logical unit.
class _BrowserScreenState extends _BrowserScreenStateBase
    with
        _ShortcutsMixin,
        _TabsMixin,
        _WebViewMixin,
        _PopupsAdsMixin,
        _NavigationMenuMixin,
        _MediaDownloadsMixin,
        _DashboardMixin,
        _LifecycleMixin,
        _BuildMixin {}
