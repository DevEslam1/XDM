import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/downloads/models/download_task.dart';

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
      'settings_engine_status': 'Download engine status',
      'settings_auto_resume': 'Auto-resume downloads',
      'settings_auto_resume_sub': 'Resume unfinished downloads on startup',
      'settings_max_channels': 'Max active downloads',
      'settings_max_channels_sub': 'Limit concurrent downloads',
      'settings_bandwidth': 'Speed & connections',
      'settings_speed_limit': 'Global speed limit',
      'settings_unlimited': 'Unlimited bandwidth',
      'settings_limit_to': 'Mb/s maximum',
      'settings_wifi_only': 'Wifi-only mode',
      'settings_wifi_only_sub': 'Pause downloads on mobile networks',
      'settings_cockpit': 'Interface styling',
      'settings_glow': 'Enable neon glow accents',
      'settings_glow_sub': 'Draw glowing drop shadows on buttons',
      'settings_grid': 'Background grid density',
      'settings_grid_sub': 'Intensity',
      'settings_alerters': 'Alert sounds',
      'settings_chime': 'Completion audible chime',
      'settings_chime_sub': 'Play audio ping when download completes',
      'settings_haptic': 'Haptic feedback pulses',
      'settings_haptic_sub': 'Vibrate device on key transitions',
      'settings_theme': 'Visual mode style',
      'settings_theme_sub': 'Dark mode engine',
      'settings_lang': 'Language',
      'settings_lang_sub': 'Select interface localization',
      'settings_default_threads': 'Default connections (threads)',
      'settings_default_threads_sub':
          'Default connection threads count for new downloads',
      'settings_about': 'About xdm',
      'settings_firmware': 'Firmware',
      'settings_about_desc':
          'High-efficiency parallel multithreaded download processor.',
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
      'delete_desc': 'Are you sure you want to remove this download from the list?',
      'delete_btn': 'Delete',
      'cancel_btn': 'Cancel',
      'delete_files_label': 'Delete downloaded files/parts from disk',
      'seeds': 'Seeds',
      'peers': 'Peers',
      'pause_btn': 'Pause',
      'clipboard_detected': 'Clipboard link detected',
      'clipboard_desc': 'XDM detected a download link in your clipboard:',
      'clipboard_ignore': 'Ignore',
      'clipboard_establish': 'Download',
      'onboarding_title_1': 'Max speed engine',
      'onboarding_sub_1':
          'Accelerate download speeds with multi-threaded chunking pipelines.',
      'onboarding_title_2': 'Smart categories',
      'onboarding_sub_2':
          'Auto-organize your files into categorized folders cleanly.',
      'onboarding_title_3': 'Easy management',
      'onboarding_sub_3':
          'Complete control with connection settings, grid styles, and scheduling.',
      'onboarding_start': 'Get started',
      'onboarding_next': 'Next',
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
      'settings_classic_ui_sub':
          'Switch to a flat native UI design styling',

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
      'link_updated_success': 'Link updated successfully. You can resume download now.',
      'torrent_connection_status': 'Torrent connection status',
      'download': 'Download',
      'upload': 'Upload',
      'overall_progress': 'Overall progress',
      'transferred': 'Transferred',
      'confirm_close_tab_title': 'Confirm Close Tab',
      'confirm_close_tab_desc': 'This tab has an active download. Close anyway?',
    },
    'ar': {
      'app_title': 'XDM',
      'title_transmissions': 'التنزيلات',
      'title_categories': 'التصنيفات',
      'title_browser': 'المتصفح',
      'title_history': 'السجل',
      'title_config': 'الإعدادات',
      'config_header': 'الإعدادات',
      'settings_engine_status': 'حالة محرك التنزيل',
      'settings_auto_resume': 'استئناف تلقائي للتنزيلات',
      'settings_auto_resume_sub': 'استئناف التنزيلات غير المكتملة عند التشغيل',
      'settings_max_channels': 'أقصى تنزيلات نشطة',
      'settings_max_channels_sub': 'تحديد التنزيلات المتزامنة',
      'settings_bandwidth': 'السرعة والاتصالات',
      'settings_speed_limit': 'حد السرعة العام',
      'settings_unlimited': 'سرعة غير محدودة',
      'settings_limit_to': 'ميغابايت/ثانية كحد أقصى',
      'settings_wifi_only': 'وضع الواي فاي فقط',
      'settings_wifi_only_sub': 'إيقاف مؤقت للتنزيل على شبكات الهاتف المحمول',
      'settings_cockpit': 'تنسيق الواجهة',
      'settings_glow': 'تفعيل توهج النيون',
      'settings_glow_sub': 'رسم ظلال متوهجة على الأزرار',
      'settings_grid': 'كثافة شبكة الخلفية',
      'settings_grid_sub': 'مستوى الشدة',
      'settings_alerters': 'أصوات التنبيه',
      'settings_chime': 'رنين التنبيه بالاكتمال',
      'settings_chime_sub': 'تشغيل نغمة عند اكتمال التنزيل',
      'settings_haptic': 'نبضات الاهتزاز التفاعلية',
      'settings_haptic_sub': 'اهتزاز الجهاز عند الانتقالات الرئيسية',
      'settings_theme': 'النمط البصري للواجهة',
      'settings_theme_sub': 'محرك الوضع المظلم',
      'settings_lang': 'اللغة',
      'settings_lang_sub': 'اختر لغة واجهة المستخدم',
      'settings_default_threads': 'خيوط الاتصال الافتراضية',
      'settings_default_threads_sub':
          'عدد خيوط الأجزاء الافتراضية للتنزيلات الجديدة',
      'settings_about': 'حول XDM',
      'settings_firmware': 'البرنامج الثابت',
      'settings_about_desc':
          'معالج تنزيل متوازي متعدد الخيوط عالي الكفاءة.',
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
      'pause_btn': 'إيقاف مؤقت',
      'clipboard_detected': 'تم كشف رابط في الحافظة',
      'clipboard_desc': 'اكتشف XDM رابطًا في حافظتك:',
      'clipboard_ignore': 'تجاهل',
      'clipboard_establish': 'تنزيل',
      'onboarding_title_1': 'محرك السرعة القصوى',
      'onboarding_sub_1':
          'تسريع التنزيل عن طريق تقسيم الملفات عبر خيوط متعددة.',
      'onboarding_title_2': 'التصنيف الذكي',
      'onboarding_sub_2': 'تنظيم تلقائي لملفاتك داخل مجلدات تصنيفات فرعية.',
      'onboarding_title_3': 'إدارة سهلة',
      'onboarding_sub_3':
          'تحكم كامل عبر إعدادات الاتصال، الجدولة، وأنماط الشبكة.',
      'onboarding_start': 'بدء الاستخدام',
      'onboarding_next': 'التالي',
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
      'settings_classic_ui_sub':
          'التبديل إلى نمط واجهة مستخدم مسطح وبسيط',

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
    return Provider.of<SettingsProvider>(context, listen: listen).languageCode ==
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
    if (!isRtl(context)) return rawEta;
    switch (status) {
      case DownloadStatus.completed:
        if (rawEta == 'Seeding') return 'مشاركة (Seeding)';
        return 'مكتمل';
      case DownloadStatus.queued:
        return 'في الانتظار';
      case DownloadStatus.paused:
        return 'موقوف';
      case DownloadStatus.failed:
        return 'فشل';
      case DownloadStatus.downloading:
        return rawEta
            .replaceAllMapped(RegExp(r'(\d+)\s*h\b'), (m) => '${m[1]}س')
            .replaceAllMapped(RegExp(r'(\d+)\s*m\b'), (m) => '${m[1]}د')
            .replaceAllMapped(RegExp(r'(\d+)\s*s\b'), (m) => '${m[1]}ث')
            .replaceAll(RegExp(r'\bleft\b'), 'متبقي');
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
