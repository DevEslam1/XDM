import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/downloads/models/download_task.dart';

// TODO (perf): Split _translations into separate files per locale and lazy-load
// only the selected language to reduce memory usage.
// Consider using .arb files with flutter_localizations for standard i18n.

class L10n {
  static const Map<String, Map<String, String>> _translations = {
    'en': {
      'app_title': 'Xdm',
      'title_transmissions': 'Downloads',
      'title_categories': 'Categories',
      'title_browser': 'Browser',
      'title_history': 'History',
      'title_config': 'Settings',
      'config_header': 'Settings',
      'settings_engine_status': 'Engine Status',
      'settings_auto_resume': 'Auto-resume Downloads',
      'settings_auto_resume_sub': 'Resume unfinished downloads on app launch',
      'settings_max_channels': 'Max Concurrent Downloads',
      'settings_max_channels_sub': 'Limit active parallel downloads',
      'settings_bandwidth': 'Network & Speed Limits',
      'settings_speed_limit': 'Global Download Speed Limit',
      'settings_unlimited': 'Unlimited',
      'settings_limit_to': 'MB/s Max',
      'settings_wifi_only': 'Wi-Fi Only Mode',
      'settings_wifi_only_sub': 'Pause downloads when on cellular data',
      'settings_cockpit': 'App Interface & Theme',
      'settings_glow': 'Neon Glow Effects',
      'settings_glow_sub':
          'Show subtle glowing highlights on active UI elements',
      'settings_grid': 'Background Grid Pattern',
      'settings_grid_sub': 'Grid Density',
      'settings_alerters': 'Sound & Alerts',
      'settings_chime': 'Completion Notification Chime',
      'settings_chime_sub': 'Play a sound when a download completes',
      'settings_haptic': 'Haptic Touch Feedback',
      'settings_haptic_sub': 'Vibrate device on button taps and tab switches',
      'settings_theme': 'Theme Mode',
      'settings_theme_sub': 'Choose appearance theme',
      'settings_lang': 'Language',
      'settings_lang_sub': 'Select app display language',
      'settings_default_threads': 'Default Connection Threads',
      'settings_default_threads_sub':
          'Number of parallel connection threads for new downloads',
      'settings_about': 'About XDM',
      'settings_firmware': 'Version',
      'settings_about_desc':
          'High-performance multi-threaded download manager and web browser.',
      'add_download': 'Add new download',
      'add_download_url': 'Download url / link',
      'add_download_name': 'File name (optional)',
      'add_download_path': 'Save location',
      'add_download_category': 'Category',
      'add_download_threads': 'Connections (threads)',
      'add_download_schedule': 'Schedule download',
      'add_download_schedule_sub': 'Enable delayed activation',
      'add_download_adv': 'Advanced options',
      'add_download_start': 'Start download',
      'add_download_close': 'Close',
      'add_download_empty_url': 'Url link required',
      'add_download_invalid_url': 'Invalid http/https url',
      'delete_title': 'Delete download',
      'delete_desc':
          'Are you sure you want to remove this download from the list?',
      'delete_btn': 'Delete',
      'cancel_btn': 'Cancel',
      'delete_files_label': 'Delete downloaded files/parts from disk',
      'seeds': 'Seeds',
      'peers': 'Peers',
      'resume_btn': 'Resume',
      'pause_btn': 'Pause',
      'pause_all_btn': 'Pause All',
      'resume_all_btn': 'Resume All',
      'clipboard_detected': 'Clipboard link detected',
      'clipboard_desc': 'XDM detected a download link in your clipboard:',
      'clipboard_ignore': 'Ignore',
      'clipboard_establish': 'Download',
      'onboarding_title_1': 'Speed engine',
      'onboarding_sub_1':
          'Multi-threaded downloads with smart resume for maximum speed.',
      'onboarding_title_2': 'Any site',
      'onboarding_sub_2':
          'Download from YouTube, Facebook, Twitter, TikTok, Instagram, and hundreds more.',
      'onboarding_title_3': 'Torrent ready',
      'onboarding_sub_3':
          'Full torrent support with DHT, encryption, per-file selection, and seeding.',
      'onboarding_title_4': 'Smart control',
      'onboarding_sub_4':
          'Auto-categorization, scheduling, Wi-Fi guard, and dark/light themes.',
      'onboarding_start': 'Get started',
      'onboarding_next': 'Next',
      'onboarding_skip': 'Skip',
      'permission_title': 'App Permissions',
      'permission_subtitle':
          'Allow the following permissions for the best experience',
      'permission_storage_title': 'Storage',
      'permission_storage_desc': 'Save downloaded files to your device',
      'permission_notifications_title': 'Notifications',
      'permission_notifications_desc': 'Get notified when downloads complete',
      'permission_battery_title': 'Battery Optimization',
      'permission_battery_desc': 'Allow uninterrupted downloads in background',
      'permission_battery_opening': 'Opening system settings…',
      'permission_continue': 'Continue',
      'permission_allow': 'Allow',
      'details_title': 'Download details',
      'details_channels': 'Connections',
      'details_active_threads': 'Threads active',
      'details_metadata': 'File information',
      'details_filename': 'File name',
      'details_url': 'Source url',
      'details_path': 'Save path',
      'details_local_file': 'Local file',
      'details_size': 'File size',
      'details_transferred': 'Transferred',
      'details_category': 'Category',
      'details_error': 'Last error',
      'details_status': 'Status',
      'details_established': 'Added on',
      'details_inactive_eta': 'Eta: inactive',
      'details_threads_warning_title': 'Restructure connection threads?',
      'details_threads_warning_desc':
          'Changing connection threads on an active or paused download will reset progress. Do you want to proceed?',
      'sort_date': 'Date',
      'sort_status': 'Status',
      'search_placeholder': 'Filter downloads...',
      'stats_downloading': 'Downloading',
      'stats_completed': 'Completed',
      'stats_failed': 'Failed',
      'stats_active': 'Active',
      'history_empty': 'No completed downloads',
      'history_desc': 'Transferred files index is currently empty.',
      'category_overview': 'Storage analytics',
      'category_files': 'Files',
      'empty_transmissions': 'No active downloads',

      'settings_youtube_backend': 'Backend configuration',
      'settings_adv_console': 'Advanced settings',
      'settings_ua': 'Custom user-agent',
      'settings_ua_sub': 'Override default HTTP client headers',
      'settings_proxy': 'Routing proxy tunnel',
      'settings_proxy_sub': 'Redirect connection data streams',
      'settings_proxy_address': 'Proxy address (ip:port)',
      'settings_bypass_ssl': 'Trust all ssl certificates',
      'settings_bypass_ssl_sub':
          'Bypass SSL validation (WARNING: MITM vulnerability)',
      'settings_reduce_visuals': 'Reduce visual effects',
      'settings_reduce_visuals_sub':
          'Disable blur and glow effects for better performance',
      'settings_classic_ui': 'Classic ui mode',
      'settings_classic_ui_sub': 'Switch to a flat native UI design styling',

      'settings_cleanup': 'Auto-cleanup logs',
      'settings_cleanup_sub': 'Purge completed task histories',
      'settings_subfolders': 'Categorized directories',
      'settings_subfolders_sub': 'Save classified files into subfolders',
      'settings_backup_title': 'System backups',
      'settings_backup_sub': 'Archive and retrieve download logs',
      'settings_export': 'Export backup',
      'settings_import': 'Import backup',
      'settings_developer': 'Developer',
      'developer_title': 'Mobile Development Engineer',
      'developer_email': 'xdev.eslam@gmail.com',
      'developer_github': 'github.com/DevEslam1',
      'developer_linkedin': 'linkedin.com/in/deveslam-mahmoud',
      'developer_phone': '+20 112 229 9831',
      'tap_to_copy': 'Tap to copy',
      'tap_to_open': 'Tap to open',
      'copied': 'Copied to clipboard!',
      'settings_auto_retry': 'Auto-retry failed downloads',
      'settings_auto_retry_sub': 'Automatically retry on failure',
      'settings_retry_max': 'Max retry attempts',
      'settings_retry_max_sub': 'Number of automatic retry attempts',
      'settings_retry_delay': 'Retry delay',
      'settings_retry_delay_sub': 'Seconds between retry attempts',
      'settings_retry_5s': '5 seconds',
      'settings_retry_10s': '10 seconds',
      'settings_retry_30s': '30 seconds',
      'settings_retry_60s': '60 seconds',
      'download_file_title': 'Download file!',
      'link_label': 'Link:',
      'save_as_label': 'Save as:',
      'size_label': 'Size: ',
      'storage_label': 'Storage: ',
      'wifi_only_label': 'Wifi only',
      'retry_label': 'Retry',
      'use_proxy_label': 'Use proxy',
      'hidden_file_label': 'Hidden file',
      'use_advance_download_label': 'Use advance download method',
      'advance_option_label': 'Advance option',
      'category_label': 'Category: ',
      'threads_label': 'Threads: ',
      'cancel_btn_uppercase': 'Cancel',
      'connect_btn': 'Connect',
      'add_btn': 'Add',
      'free_label': 'free',
      'unknown_label': 'Unknown',
      'url_empty_error': 'Please enter a URL',
      'url_invalid_error': 'Please enter a valid URL',
      'open_file_btn': 'Open file',
      'delete_success': 'Download deleted successfully',
      'task_not_found': 'Download task not found',
      'torrent_included_files': 'Torrent included files',
      'disk_verified': 'Disk verified',
      'adjust_threads': 'Adjust connection threads',
      'channel_label': 'Ch',
      'url_copied': 'URL copied to clipboard',
      'origin_download_page': 'Origin download page',
      'page_url_copied': 'Page URL copied to clipboard',
      'audio_url': 'Audio url',
      'audio_size': 'Audio size',
      'audio_download': 'Audio download',
      'bandwidth_controls': 'Bandwidth speed controls',
      'download_speed_limit': 'Download speed limit',
      'unlimited_speed': 'Unlimited speed',
      'torrent_seeding_interface': 'Torrent seeding interface',
      'seeding_transmission': 'Seeding transmission',
      'active_on_completion': 'Seed after completion',
      'disabled': 'Disabled',
      'limit_upload_speed': 'Limit upload speed',
      'unlimited_upload': 'Unlimited upload',
      'update_download_link': 'Update download link',
      'enter_new_url': 'Enter the new URL to continue downloading:',
      'link_updated_success':
          'Link updated successfully. You can resume download now.',
      'torrent_connection_status': 'Torrent connection status',
      'download': 'Download',
      'upload': 'Upload',
      'overall_progress': 'Overall progress',
      'transferred': 'Transferred',
      'confirm_close_tab_title': 'Confirm Close Tab',
      'confirm_close_tab_desc':
          'This tab has an active download. Close anyway?',
      'file_name_label': 'File name:',
      'save_path_label': 'Save path:',
      'filename_empty_error': 'Filename cannot be empty',
      'auto_retry_label': 'Auto-retry',
      'yt_playlist': 'YOUTUBE PLAYLIST',
      'loading_playlist': 'Loading playlist...',
      'retry_btn': 'RETRY',
      'active_tabs': 'ACTIVE TABS',
      'search_videos': 'Search videos...',
      'select_all': 'SELECT ALL',
      'deselect_all': 'DESELECT ALL',
      'yt_video_quality': 'YOUTUBE VIDEO QUALITY',
      'fetching_streams': 'Fetching available streams...',
      'video_label': 'VIDEO',
      'audio_label': 'AUDIO',
      'quality_label': 'QUALITY',
      'yt_legal_warning':
          'Notice: Download content only if you own it or have explicit authorization from the copyright holder.',

      // Browser – general
      'browser_new_tab': 'New Tab',
      'browser_dashboard': 'Dashboard',
      'browser_bookmark_saved': 'Bookmark saved',
      'browser_url_copied': 'URL copied',
      'browser_desktop_mode_reload': 'Desktop mode — reloading',
      'browser_mobile_mode_reload': 'Mobile mode — reloading',
      'browser_media_detector_on': 'Media detector enabled',
      'browser_media_detector_off': 'Media detector disabled',
      'browser_incognito_on': 'Incognito mode ON — no history recorded',
      'browser_incognito_off': 'Incognito mode OFF',
      'browser_save_page_failed': 'Failed to read page content',
      'browser_page_saved': 'Page saved successfully',
      'browser_page_save_error': 'Failed to save page',
      'browser_max_tabs': 'Maximum tab limit of 10 reached.',
      'browser_playlist_enqueued': 'videos enqueued from',
      'browser_already_completed': 'This download is already completed.',
      'browser_already_in_progress': 'This download is already in progress.',
      'browser_download_resumed': 'Download resumed.',
      'browser_transmission_established':
          'TRANSMISSION ESTABLISHED. CHANNELS CONNECTED.',

      // Browser – interception sheet
      'browser_intercepted_signal': 'INTERCEPTED DOWNLOAD SIGNAL',
      'browser_xdm_scanner':
          'XDM Scanner intercepted a downloadable stream signal:',
      'browser_continue_browsing': 'CONTINUE BROWSING',
      'browser_download_btn': 'DOWNLOAD',

      // Browser – quality / media picker
      'browser_select_video_quality': 'SELECT VIDEO QUALITY',
      'browser_alternative_stream': 'Alternative Stream',
      'browser_no_alternative_streams': 'No alternative streams detected',
      'browser_detected_media': 'DETECTED MEDIA ON PAGE',
      'browser_media_stream': 'Media Stream',

      // Browser – JS-injected labels
      'browser_video_stream_default': 'Video Stream (Default)',
      'browser_resolution': 'Resolution ',
      'browser_video_poster': 'Video Poster Image',
      'browser_audio_stream': 'Audio Stream',
      'browser_lazy_video': 'Lazy-Loaded Video',
      'browser_embedded_video': 'Embedded Video',

      // Browser – default filenames
      'browser_offline_page': 'Offline_Page',
      'browser_youtube_video': 'YouTube Video',
      'browser_media_video': 'Media Video',
      'browser_torrent_download': 'Torrent Download',

      // Browser – tooltips
      'browser_new_incognito_tab': 'New Incognito Tab',
      'browser_close': 'Close browser',
      'browser_stop_loading': 'Stop loading',
      'browser_clear': 'Clear',
      'browser_refresh': 'Refresh page',
      'browser_download_playlist': 'Download Playlist',
      'browser_download_video': 'Download Video',

      // Browser – hint text
      'browser_search_web': 'Search the web...',
      'browser_search_or_enter_url': 'Search or enter URL...',

      // Browser – dashboard sections
      'browser_search_engine': 'Search Engine:',
      'browser_stream_sniffer_status': 'STREAM SNIFFER STATUS',
      'browser_auto_intercept_active': 'AUTO-INTERCEPT ACTIVE',
      'browser_auto_intercept_off': 'AUTO-INTERCEPT DEACTIVATED',
      'browser_sniff_description':
          'Sniffs media files and documents dynamically',
      'browser_quick_signals': 'QUICK SIGNALS (BOOKMARKS)',

      // Browser – popup menu
      'browser_menu_reload': 'Reload',
      'browser_menu_bookmark_page': 'Bookmark this page',
      'browser_menu_bookmarks_manager': 'Bookmarks Manager',
      'browser_menu_history': 'Browser History',
      'browser_menu_copy_url': 'Copy URL',
      'browser_menu_share_url': 'Share URL',
      'browser_menu_save_offline': 'Save Page Offline',
      'browser_menu_inject_js_css': 'Inject JS / CSS',
      'browser_menu_mobile_mode': 'Mobile mode',
      'browser_menu_desktop_mode': 'Desktop mode',
      'browser_menu_media_detector_on': 'Media detector: ON',
      'browser_menu_media_detector_off': 'Media detector: OFF',
      'browser_menu_exit_incognito': 'Exit incognito',
      'browser_menu_new_incognito': 'New incognito tab',

      // Browser – dialogs
      'browser_download_choice': 'What do you want to download?',
      'browser_single_and_playlist':
          'This link contains both a single video and a playlist.',
      'browser_single_video': 'Single Video',
      'browser_entire_playlist': 'Entire Playlist',

      // Browser – FAB
      'browser_fab_playlist': 'PLAYLIST',
      'browser_fab_media': 'MEDIA',
      'browser_fab_youtube_retry': 'YOUTUBE (RETRY)',
      'browser_fab_downloads': 'DOWNLOADS',

      // Browser – JS/CSS Injector
      'browser_js_css_injector': 'JS / CSS INJECTOR',
      'browser_js_css_warning':
          'WARNING: Code runs on web pages. Do not enter sensitive data.',
      'browser_javascript': 'JavaScript',
      'browser_css_style': 'CSS Style',
      'browser_cancel_uppercase': 'CANCEL',
      'browser_apply_uppercase': 'APPLY',

      // Browser – history sheet
      'browser_history_title': 'BROWSER HISTORY',
      'browser_download_history': 'DOWNLOAD HISTORY',
      'browser_surfing_history': 'Surfing History',
      'browser_downloads_tab': 'Downloads',
      'browser_close_btn': 'CLOSE',
      'browser_clear_search': 'CLEAR SEARCH',
      'browser_export_json': 'Export to JSON',
      'browser_clear_history_btn': 'Clear history',
      'browser_search_history_hint': 'Search history...',
      'browser_no_results_for': 'No results for',
      'browser_no_history_found': 'No history found',
      'browser_no_history_desc': 'Websites you visit will be listed here.',
      'browser_no_downloads_yet': 'No downloads yet',
      'browser_no_downloads_desc':
          'Files you download from the browser will appear here.',
      'browser_clear_history_title': 'CLEAR HISTORY?',
      'browser_clear_history_desc':
          'Are you sure you want to clear all history?',
      'browser_clear_history_content':
          'Are you sure you want to clear all browsing history?',
      'browser_export_failed': 'Export failed',
      'browser_copied_url_for': 'Copied URL for:',
      'browser_status_done': 'DONE',
      'browser_status_active': 'ACTIVE',
      'browser_status_paused': 'PAUSED',
      'browser_status_failed': 'FAILED',
      'browser_status_queued': 'QUEUED',

      // Browser – bookmark manager
      'browser_bookmarks': 'BOOKMARKS',
      'browser_add_bookmark': 'Add bookmark',
      'browser_edit_bookmark': 'Edit bookmark',
      'browser_delete': 'Delete',
      'browser_no_bookmarks': 'No bookmarks yet',
      'browser_no_bookmarks_desc': 'Tap + to save your favorite sites',
      'browser_title_label': 'Title',
      'browser_url_label': 'URL',
      'browser_folder_optional': 'Folder (optional)',
      'browser_save_btn': 'SAVE',
      'browser_quit': 'Quit browser',
      'browser_tabs_restored': 'Previous tabs restored',
    },
    'ar': {
      'app_title': 'XDM',
      'title_transmissions': 'التنزيلات',
      'title_categories': 'التصنيفات',
      'title_browser': 'المتصفح',
      'title_history': 'السجل',
      'title_config': 'الإعدادات',
      'config_header': 'الإعدادات',
      'settings_engine_status': 'حالة المحرك',
      'settings_auto_resume': 'الاستئناف التلقائي للتنزيلات',
      'settings_auto_resume_sub': 'استئناف التنزيلات المتبقية عند فتح التطبيق',
      'settings_max_channels': 'أقصى عدد للتنزيلات المتزامنة',
      'settings_max_channels_sub':
          'تحديد عدد الملفات التي يتم تنزيلها في وقت واحد',
      'settings_bandwidth': 'إعدادات الشبكة والسرعة',
      'settings_speed_limit': 'حد سرعة التنزيل العام',
      'settings_unlimited': 'غير محدود',
      'settings_limit_to': 'ميجابايت/ثانية كحد أقصى',
      'settings_wifi_only': 'الواي فاي فقط',
      'settings_wifi_only_sub':
          'إيقاف التنزيلات مؤقتاً عند استخدام بيانات الهاتف',
      'settings_cockpit': 'المظهر والواجهة',
      'settings_glow': 'تأثيرات التوهج النيوني',
      'settings_glow_sub': 'إظهار إضاءة خفيفة حول الأزرار والتطبيقات',
      'settings_grid': 'شبكة الخلفية',
      'settings_grid_sub': 'كثافة النمط',
      'settings_alerters': 'الصوت والتنبيهات',
      'settings_chime': 'تنبيه اكتمال التنزيل',
      'settings_chime_sub': 'تشغيل صوت تنبيه عند انتهاء تنزيل الملف',
      'settings_haptic': 'الاهتزاز والتفاعل اللمسي',
      'settings_haptic_sub': 'اهتزاز خفيف عند الضغط والتنقل بين التبويبات',
      'settings_theme': 'نمط المظهر',
      'settings_theme_sub': 'اختيار المظهر الداكن أو الفاتح',
      'settings_lang': 'لغة التطبيق',
      'settings_lang_sub': 'تغيير لغة الواجهة',
      'settings_default_threads': 'عدد الاتصالات التلقائي (Threads)',
      'settings_default_threads_sub':
          'عدد أجزاء التنزيل المتوازية للملفات الجديدة',
      'settings_about': 'عن XDM',
      'settings_firmware': 'الإصدار',
      'settings_about_desc':
          'مدير تنزيلات سريع متعدد الأجزاء ومتصفح ويب متكامل.',
      'add_download': 'إضافة تنزيل جديد',
      'add_download_url': 'رابط التنزيل (URL)',
      'add_download_name': 'اسم الملف (اختياري)',
      'add_download_path': 'مكان الحفظ',
      'add_download_category': 'التصنيف',
      'add_download_threads': 'خيوط الاتصال (الخيوط)',
      'add_download_schedule': 'جدولة التنزيل',
      'add_download_schedule_sub': 'تفعيل التنزيل المؤجل',
      'add_download_adv': 'خيارات متقدمة',
      'add_download_start': 'بدء التنزيل',
      'add_download_close': 'إغلاق',
      'add_download_empty_url': 'الرابط مطلوب',
      'add_download_invalid_url': 'الرابط غير صالح',
      'delete_title': 'حذف التنزيل',
      'delete_desc': 'هل أنت متأكد من حذف هذا التنزيل من القائمة؟',
      'delete_btn': 'حذف',
      'cancel_btn': 'إلغاء',
      'delete_files_label': 'حذف الملفات/الأجزاء المحملة من القرص',
      'seeds': 'المصادر',
      'peers': 'النظراء',
      'resume_btn': 'استئناف',
      'pause_btn': 'إيقاف مؤقت',
      'pause_all_btn': 'إيقاف الكل',
      'resume_all_btn': 'استئناف الكل',
      'clipboard_detected': 'تم كشف رابط في الحافظة',
      'clipboard_desc': 'اكتشف XDM رابطًا في حافظتك:',
      'clipboard_ignore': 'تجاهل',
      'clipboard_establish': 'تنزيل',
      'onboarding_title_1': 'محرك السرعة',
      'onboarding_sub_1': 'تنزيل متعدد الخيوط مع استئناف ذكي لأقصى سرعة.',
      'onboarding_title_2': 'أي موقع',
      'onboarding_sub_2':
          'تنزيل من يوتيوب، فيسبوك، تويتر، تيك توك، إنستغرام، ومئات المواقع الأخرى.',
      'onboarding_title_3': 'تورنت',
      'onboarding_sub_3':
          'دعم كامل للتورنت مع DHT، تشفير، اختيار الملفات، والبذر.',
      'onboarding_title_4': 'تحكم ذكي',
      'onboarding_sub_4':
          'تصنيف تلقائي، جدولة، حماية الواي فاي، وثيمات مظلمة/فاتحة.',
      'onboarding_start': 'بدء الاستخدام',
      'onboarding_next': 'التالي',
      'onboarding_skip': 'تخطي',
      'permission_title': 'أذونات التطبيق',
      'permission_subtitle': 'اسمح بالأذونات التالية للحصول على أفضل تجربة',
      'permission_storage_title': 'التخزين',
      'permission_storage_desc': 'حفظ الملفات التي تم تحميلها على جهازك',
      'permission_notifications_title': 'الإشعارات',
      'permission_notifications_desc': 'احصل على إشعار عند اكتمال التحميل',
      'permission_battery_title': 'تحسين البطارية',
      'permission_battery_desc': 'السماح بالتحميل دون انقطاع في الخلفية',
      'permission_battery_opening': 'جاري فتح الإعدادات…',
      'permission_continue': 'متابعة',
      'permission_allow': 'السماح',
      'details_title': 'تفاصيل التنزيل',
      'details_channels': 'خيوط الاتصال',
      'details_active_threads': 'خيوط نشطة',
      'details_metadata': 'معلومات الملف',
      'details_filename': 'اسم الملف',
      'details_url': 'رابط المصدر',
      'details_path': 'مسار الحفظ',
      'details_local_file': 'الملف المحلي',
      'details_size': 'حجم الملف',
      'details_transferred': 'تم نقله',
      'details_category': 'التصنيف',
      'details_error': 'آخر خطأ',
      'details_status': 'الحالة',
      'details_established': 'تاريخ الإضافة',
      'details_inactive_eta': 'الوقت المقدر: غير نشط',
      'details_threads_warning_title': 'إعادة تعيين خيوط الاتصال؟',
      'details_threads_warning_desc':
          'تغيير خيوط الاتصال على تنزيل نشط أو مؤقت سيؤدي إلى إعادة تعيين تقدمك. هل تريد الاستمرار؟',
      'sort_date': 'التاريخ',
      'sort_status': 'الحالة',
      'search_placeholder': 'تصفية التنزيلات...',
      'stats_downloading': 'جاري التحميل',
      'stats_completed': 'المكتملة',
      'stats_failed': 'الفاشلة',
      'stats_active': 'النشطة',
      'history_empty': 'لا توجد تنزيلات مكتملة',
      'history_desc': 'فهرس الملفات المنقولة فارغ حالياً.',
      'category_overview': 'تحليل مساحة التخزين',
      'category_files': 'ملفات',
      'empty_transmissions': 'لا توجد تنزيلات نشطة',

      'settings_youtube_backend': 'إعدادات الخادم الخلفي',
      'settings_adv_console': 'إعدادات متقدمة',
      'settings_ua': 'عميل مستخدم مخصص (User-Agent)',
      'settings_ua_sub': 'تجاوز ترويسات عميل HTTP الافتراضية',
      'settings_proxy': 'نفق البروكسي الموجه',
      'settings_proxy_sub': 'توجيه تدفق بيانات الاتصال',
      'settings_proxy_address': 'عنوان البروكسي (IP:PORT)',
      'settings_bypass_ssl': 'الوثوق بجميع شهادات SSL',
      'settings_bypass_ssl_sub':
          'تجاوز التحقق من الشهادات (تحذير: عرضة للاختراق)',
      'settings_reduce_visuals': 'تقليل التأثيرات البصرية',
      'settings_reduce_visuals_sub':
          'تعطيل تأثيرات التمويه والتوهج لتحسين الأداء',
      'settings_classic_ui': 'المظهر الكلاسيكي',
      'settings_classic_ui_sub': 'التبديل إلى نمط واجهة مستخدم مسطح وبسيط',

      'settings_cleanup': 'التنظيف التلقائي للسجلات',
      'settings_cleanup_sub': 'حذف تاريخ المهام المكتملة',
      'settings_subfolders': 'مجلدات التصنيفات الفرعية',
      'settings_subfolders_sub': 'حفظ الملفات المصنفة داخل مجلدات فرعية',
      'settings_backup_title': 'النسخ الاحتياطي للنظام',
      'settings_backup_sub': 'أرشفة واسترجاع سجلات التنزيل',
      'settings_export': 'تصدير النسخة الاحتياطية',
      'settings_import': 'استيراد النسخة الاحتياطية',
      'settings_developer': 'المطور',
      'developer_title': 'مهندس تطوير تطبيقات الجوال',
      'developer_email': 'xdev.eslam@gmail.com',
      'developer_github': 'github.com/DevEslam1',
      'developer_linkedin': 'linkedin.com/in/deveslam-mahmoud',
      'developer_phone': '+20 112 229 9831',
      'tap_to_copy': 'اضغط للنسخ',
      'tap_to_open': 'اضغط للفتح',
      'copied': 'تم النسخ إلى الحافظة!',
      'settings_auto_retry': 'إعادة المحاولة التلقائية للتنزيلات الفاشلة',
      'settings_auto_retry_sub': 'إعادة محاولة التنزيل تلقائياً عند الفشل',
      'settings_retry_max': 'الحد الأقصى لإعادة المحاولة',
      'settings_retry_max_sub': 'عدد محاولات إعادة المحاولة التلقائية',
      'settings_retry_delay': 'تأخير إعادة المحاولة',
      'settings_retry_delay_sub': 'الثواني بين كل محاولة وأخرى',
      'settings_retry_5s': '5 ثوانٍ',
      'settings_retry_10s': '10 ثوانٍ',
      'settings_retry_30s': '30 ثانية',
      'settings_retry_60s': '60 ثانية',
      'download_file_title': 'تنزيل الملف!',
      'link_label': 'الرابط:',
      'save_as_label': 'حفظ باسم:',
      'size_label': 'الحجم: ',
      'storage_label': 'التخزين: ',
      'wifi_only_label': 'واي فاي فقط',
      'retry_label': 'إعادة المحاولة',
      'use_proxy_label': 'استخدام بروكسي',
      'hidden_file_label': 'ملف مخفي',
      'use_advance_download_label': 'استخدام طريقة التنزيل المتقدمة',
      'advance_option_label': 'خيارات متقدمة',
      'category_label': 'التصنيف: ',
      'threads_label': 'الخيوط: ',
      'cancel_btn_uppercase': 'إلغاء',
      'connect_btn': 'الاتصال',
      'add_btn': 'إضافة',
      'free_label': 'خالٍ',
      'unknown_label': 'غير معروف',
      'url_empty_error': 'الرجاء إدخال رابط',
      'url_invalid_error': 'الرجاء إدخال رابط صالح',
      'file_name_label': 'اسم الملف:',
      'save_path_label': 'مسار الحفظ:',
      'filename_empty_error': 'اسم الملف لا يمكن أن يكون فارغاً',
      'auto_retry_label': 'إعادة محاولة تلقائية',
      'open_file_btn': 'فتح الملف',
      'delete_success': 'تم حذف التنزيل بنجاح',
      'task_not_found': 'لم يتم العثور على مهمة التنزيل',
      'torrent_included_files': 'ملفات التورنت المضمنة',
      'disk_verified': 'تم التحقق من القرص',
      'adjust_threads': 'تعديل عدد خيوط الاتصال',
      'channel_label': 'قناة',
      'url_copied': 'تم نسخ الرابط إلى الحافظة',
      'origin_download_page': 'صفحة التنزيل الأصلية',
      'page_url_copied': 'تم نسخ رابط الصفحة إلى الحافظة',
      'audio_url': 'رابط الصوت',
      'audio_size': 'حجم الصوت',
      'audio_download': 'تنزيل الصوت',
      'bandwidth_controls': 'التحكم في سرعة النطاق الترددي',
      'download_speed_limit': 'حد سرعة التنزيل',
      'unlimited_speed': 'سرعة غير محدودة',
      'torrent_seeding_interface': 'واجهة مشاركة التورنت',
      'seeding_transmission': 'نقل المشاركة (Seeding)',
      'active_on_completion': 'المشاركة بعد الاكتمال',
      'disabled': 'معطل',
      'limit_upload_speed': 'حد سرعة الرفع',
      'unlimited_upload': 'رفع غير محدود',
      'update_download_link': 'تحديث رابط التنزيل',
      'enter_new_url': 'أدخل الرابط الجديد لاستكمال التنزيل:',
      'link_updated_success':
          'تم تحديث الرابط بنجاح. يمكنك استئناف التنزيل الآن.',
      'torrent_connection_status': 'حالة اتصال التورنت',
      'download': 'تنزيل',
      'upload': 'رفع',
      'overall_progress': 'التقدم العام',
      'transferred': 'تم النقل',
      'confirm_close_tab_title': 'تأكيد إغلاق التبويب',
      'confirm_close_tab_desc':
          'يوجد تنزيل نشط في هذا التبويب. هل تريد الإغلاق؟',
      'yt_playlist': 'قائمة تشغيل يوتيوب',
      'loading_playlist': 'جاري تحميل قائمة التشغيل...',
      'retry_btn': 'إعادة المحاولة',
      'active_tabs': 'التبويبات النشطة',
      'search_videos': 'البحث عن الفيديوهات...',
      'select_all': 'تحديد الكل',
      'deselect_all': 'إلغاء تحديد الكل',
      'yt_video_quality': 'جودة فيديو يوتيوب',
      'fetching_streams': 'جاري جلب البث المتاح...',
      'video_label': 'فيديو',
      'audio_label': 'صوت',
      'quality_label': 'الجودة',
      'yt_legal_warning':
          'تنبيه: قم بتحميل المحتوى فقط إذا كنت تملكه أو لديك إذن صريح من صاحب حقوق النشر.',

      // Browser – general
      'browser_new_tab': 'تبويب جديد',
      'browser_dashboard': 'لوحة التحكم',
      'browser_bookmark_saved': 'تم حفظ الإشارة المرجعية',
      'browser_url_copied': 'تم نسخ الرابط',
      'browser_desktop_mode_reload': 'وضع سطح المكتب — جاري إعادة التحميل',
      'browser_mobile_mode_reload': 'وضع الجوال — جاري إعادة التحميل',
      'browser_media_detector_on': 'تم تفعيل كاشف الوسائط',
      'browser_media_detector_off': 'تم تعطيل كاشف الوسائط',
      'browser_incognito_on': 'وضع التصفح الخفي مفعّل — لا يتم تسجيل السجل',
      'browser_incognito_off': 'وضع التصفح الخفي معطّل',
      'browser_save_page_failed': 'فشل في قراءة محتوى الصفحة',
      'browser_page_saved': 'تم حفظ الصفحة بنجاح',
      'browser_page_save_error': 'فشل في حفظ الصفحة',
      'browser_max_tabs': 'تم الوصول إلى الحد الأقصى للمبوبات (10 مبوبات).',
      'browser_playlist_enqueued': 'فيديو تمت إضافتها إلى قائمة الانتظار من',
      'browser_already_completed': 'هذا التنزيل مكتمل بالفعل.',
      'browser_already_in_progress': 'هذا التنزيل قيد التشغيل بالفعل.',
      'browser_download_resumed': 'تم استئناف التنزيل.',
      'browser_transmission_established': 'تم إنشاء الاتصال. القنوات متصلة.',

      // Browser – interception sheet
      'browser_intercepted_signal': 'تم التقاط إشارة تنزيل',
      'browser_xdm_scanner': 'اكتشف مستعرض XDM إشارة تنزيل قابلة للاعتراض:',
      'browser_continue_browsing': 'متابعة التصفح',
      'browser_download_btn': 'تحميل',

      // Browser – quality / media picker
      'browser_select_video_quality': 'اختر جودة الفيديو',
      'browser_alternative_stream': 'بث بديل',
      'browser_no_alternative_streams': 'لم يتم اكتشاف تدفقات بديلة',
      'browser_detected_media': 'وسائط مكتشفة على الصفحة',
      'browser_media_stream': 'تدفق الوسائط',

      // Browser – JS-injected labels
      'browser_video_stream_default': 'تدفق الفيديو (افتراضي)',
      'browser_resolution': 'الدقة ',
      'browser_video_poster': 'صورة ملصق الفيديو',
      'browser_audio_stream': 'تدفق الصوت',
      'browser_lazy_video': 'فيديو محمل ببطء',
      'browser_embedded_video': 'فيديو مدمج',

      // Browser – default filenames
      'browser_offline_page': 'صفحة_غير_متصلة',
      'browser_youtube_video': 'فيديو يوتيوب',
      'browser_media_video': 'فيديو وسائط',
      'browser_torrent_download': 'تنزيل تورنت',

      // Browser – tooltips
      'browser_new_incognito_tab': 'تبويب خفي جديد',
      'browser_close': 'إغلاق المتصفح',
      'browser_stop_loading': 'إلغاء التحميل',
      'browser_clear': 'مسح',
      'browser_refresh': 'إعادة تحميل الصفحة',
      'browser_download_playlist': 'تحميل قائمة التشغيل',
      'browser_download_video': 'تحميل الفيديو',

      // Browser – hint text
      'browser_search_web': 'ابحث في الويب...',
      'browser_search_or_enter_url': 'ابحث أو ادخل الرابط...',

      // Browser – dashboard sections
      'browser_search_engine': 'محرك البحث:',
      'browser_stream_sniffer_status': 'حالة كاشف الملفات',
      'browser_auto_intercept_active': 'الاعتراض التلقائي نشط',
      'browser_auto_intercept_off': 'الاعتراض التلقائي متوقف',
      'browser_sniff_description':
          'يكتشف روابط التحميل المباشرة والوسائط تلقائياً',
      'browser_quick_signals': 'إشارات سريعة (روابط)',

      // Browser – popup menu
      'browser_menu_reload': 'إعادة تحميل',
      'browser_menu_bookmark_page': 'إشارة مرجعية لهذه الصفحة',
      'browser_menu_bookmarks_manager': 'مدير الإشارات المرجعية',
      'browser_menu_history': 'سجل المتصفح',
      'browser_menu_copy_url': 'نسخ الرابط',
      'browser_menu_share_url': 'مشاركة الرابط',
      'browser_menu_save_offline': 'حفظ الصفحة بدون إنترنت',
      'browser_menu_inject_js_css': 'حقن JS / CSS',
      'browser_menu_mobile_mode': 'وضع الجوال',
      'browser_menu_desktop_mode': 'وضع سطح المكتب',
      'browser_menu_media_detector_on': 'كاشف الوسائط: مفعل',
      'browser_menu_media_detector_off': 'كاشف الوسائط: معطل',
      'browser_menu_exit_incognito': 'الخروج من التصفح الخفي',
      'browser_menu_new_incognito': 'تبويب خفي جديد',

      // Browser – dialogs
      'browser_download_choice': 'ماذا تريد تحميل؟',
      'browser_single_and_playlist': 'هذا الرابط يحتوي على فيديو وقائمة تشغيل.',
      'browser_single_video': 'فيديو واحد فقط',
      'browser_entire_playlist': 'قائمة التشغيل كاملة',

      // Browser – FAB
      'browser_fab_playlist': 'قائمة التشغيل',
      'browser_fab_media': 'الوسائط',
      'browser_fab_youtube_retry': 'يوتيوب (إعادة المحاولة)',
      'browser_fab_downloads': 'التنزيلات',

      // Browser – JS/CSS Injector
      'browser_js_css_injector': 'محقن JS / CSS',
      'browser_js_css_warning':
          'تنبيه: هذا الكود يُنفذ على صفحات الويب. لا تُدخل بيانات حساسة.',
      'browser_javascript': 'JavaScript',
      'browser_css_style': 'نمط CSS',
      'browser_cancel_uppercase': 'إلغاء',
      'browser_apply_uppercase': 'تطبيق',

      // Browser – history sheet
      'browser_history_title': 'سجل المتصفح',
      'browser_download_history': 'سجل التنزيلات',
      'browser_surfing_history': 'سجل التصفح',
      'browser_downloads_tab': 'التنزيلات',
      'browser_close_btn': 'إغلاق',
      'browser_clear_search': 'مسح البحث',
      'browser_export_json': 'تصدير إلى JSON',
      'browser_clear_history_btn': 'مسح السجل',
      'browser_search_history_hint': 'البحث في السجل...',
      'browser_no_results_for': 'لا توجد نتائج لـ',
      'browser_no_history_found': 'لا يوجد سجل',
      'browser_no_history_desc': 'سيتم عرض المواقع التي تزورها هنا.',
      'browser_no_downloads_yet': 'لا توجد تنزيلات بعد',
      'browser_no_downloads_desc': 'ستظهر الملفات التي تنزلها من المتصفح هنا.',
      'browser_clear_history_title': 'مسح السجل؟',
      'browser_clear_history_desc':
          'هل أنت متأكد من أنك تريد مسح السجل بأكمله؟',
      'browser_clear_history_content':
          'هل أنت متأكد من أنك تريد مسح سجل التصفح بالكامل؟',
      'browser_export_failed': 'فشل التصدير',
      'browser_copied_url_for': 'تم نسخ الرابط لـ:',
      'browser_status_done': 'مكتمل',
      'browser_status_active': 'نشط',
      'browser_status_paused': 'موقوف',
      'browser_status_failed': 'فشل',
      'browser_status_queued': 'في الانتظار',

      // Browser – bookmark manager
      'browser_bookmarks': 'الإشارات المرجعية',
      'browser_add_bookmark': 'إضافة إشارة مرجعية',
      'browser_edit_bookmark': 'تعديل الإشارة المرجعية',
      'browser_delete': 'حذف',
      'browser_no_bookmarks': 'لا توجد إشارات مرجعية بعد',
      'browser_no_bookmarks_desc': 'اضغط + لحفظ مواقعك المفضلة',
      'browser_title_label': 'العنوان',
      'browser_url_label': 'الرابط',
      'browser_folder_optional': 'المجلد (اختياري)',
      'browser_save_btn': 'حفظ',
      'browser_quit': 'إنهاء المتصفح',
      'browser_tabs_restored': 'تمت استعادة التبويبات السابقة',
    },
  };

  static String of(BuildContext context, String key, {bool listen = false}) {
    final lang = Provider.of<SettingsProvider>(
      context,
      listen: listen,
    ).languageCode;
    return _translations[lang]?[key] ?? key;
  }

  static String translate(String lang, String key) {
    return _translations[lang]?[key] ?? key;
  }

  static bool isRtl(BuildContext context, {bool listen = false}) {
    return Provider.of<SettingsProvider>(
          context,
          listen: listen,
        ).languageCode ==
        'ar';
  }

  static String translateCategory(BuildContext context, String cat) {
    if (!isRtl(context)) return cat;
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
      default:
        return 'أخرى';
    }
  }

  static String translateStatus(
    BuildContext context,
    DownloadStatus status,
    String rawEta,
  ) {
    if (status == DownloadStatus.downloading) {
      if (!isRtl(context)) {
        return '$rawEta left';
      }
      return '${rawEta.replaceAllMapped(RegExp(r"(\d+)\s*h\b"), (m) => "${m[1]} ساعة").replaceAllMapped(RegExp(r"(\d+)\s*m\b"), (m) => "${m[1]} دقيقة").replaceAllMapped(RegExp(r"(\d+)\s*s\b"), (m) => "${m[1]} ثانية").trim()} متبقي';
    }
    if (!isRtl(context)) return rawEta;
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
  }

  static String translateStatusName(
    BuildContext context,
    DownloadStatus status,
  ) {
    if (!isRtl(context)) {
      return switch (status) {
        DownloadStatus.downloading => 'Downloading',
        DownloadStatus.completed => 'Completed',
        DownloadStatus.paused => 'Paused',
        DownloadStatus.queued => 'Queued',
        DownloadStatus.failed => 'Failed',
      };
    }
    return switch (status) {
      DownloadStatus.downloading => 'جاري التحميل',
      DownloadStatus.completed => 'مكتمل',
      DownloadStatus.paused => 'موقوف مؤقتاً',
      DownloadStatus.queued => 'في الانتظار',
      DownloadStatus.failed => 'فشل الاتصال',
    };
  }
}
