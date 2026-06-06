import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/downloads/models/download_task.dart';

class L10n {
  static const Map<String, Map<String, String>> _translations = {
    'en': {
      'app_title': 'DMX',
      'title_transmissions': 'SIGNALS',
      'title_categories': 'CATEGORIES',
      'title_browser': 'BROWSER',
      'title_history': 'HISTORY',
      'title_config': 'CONFIG',
      'config_header': 'DMX // CONFIGURATION',
      'settings_engine_status': 'GENERAL ENGINE STATUS',
      'settings_auto_resume': 'AUTO-RESUME TRANSMISSIONS',
      'settings_auto_resume_sub': 'Resume unfinished downloads on startup',
      'settings_max_channels': 'MAX ACTIVE CHANNELS',
      'settings_max_channels_sub': 'Limit concurrent downloads',
      'settings_bandwidth': 'BANDWIDTH & OVERLAYS',
      'settings_speed_limit': 'GLOBAL SPEED LIMIT',
      'settings_unlimited': 'UNLIMITED BANDWIDTH',
      'settings_limit_to': 'MB/S MAXIMUM',
      'settings_wifi_only': 'WIFI-ONLY MODE',
      'settings_wifi_only_sub': 'Pause transmissions on mobile networks',
      'settings_cockpit': 'TACTILE COCKPIT GRAPHICS',
      'settings_glow': 'ENABLE NEON GLOW ACCENTS',
      'settings_glow_sub': 'Draw glowing drop shadows on buttons',
      'settings_grid': 'BACKGROUND GRID DENSITY',
      'settings_grid_sub': 'INTENSITY',
      'settings_alerters': 'AUDIOWAVE ALERTERS',
      'settings_chime': 'COMPLETION AUDIBLE CHIME',
      'settings_chime_sub': 'Play audio ping when transmission completes',
      'settings_haptic': 'HAPTIC FEEDBACK PULSES',
      'settings_haptic_sub': 'Vibrate device on key transitions',
      'settings_theme': 'VISUAL MODE STYLE',
      'settings_theme_sub': 'DARK MODE ENGINE',
      'settings_lang': 'COCKPIT LANGUAGE',
      'settings_lang_sub': 'Select interface localization',
      'settings_default_threads': 'DEFAULT CONNECTION CHANNELS',
      'settings_default_threads_sub': 'Default part threads count for new downloads',
      'settings_about': 'ABOUT DMX',
      'settings_firmware': 'SYSTEM FIRMWARE v2.0.26',
      'settings_about_desc': 'High-efficiency parallel multithreading transmission processor for mobile networks. Designed for low-latency signal captures.',
      'add_download': 'ESTABLISH NEW SIGNAL',
      'add_download_url': 'TARGET URL SIGNAL',
      'add_download_name': 'LOCAL IDENTITY (FILENAME)',
      'add_download_path': 'CUSTOM DOCKING PATH (SAVE DIRECTORY)',
      'add_download_category': 'SIGNAL CLASSIFICATION',
      'add_download_threads': 'CONNECTION CHANNEL COUNT (THREADS)',
      'add_download_schedule': 'SCHEDULE TRANSMISSION',
      'add_download_schedule_sub': 'Enable delayed activation',
      'add_download_adv': 'ADVANCED ROUTING OPTIONS',
      'add_download_start': 'ESTABLISH SIGNAL',
      'add_download_close': 'CLOSE',
      'add_download_empty_url': 'URL SIGNAL REQUIRED',
      'add_download_invalid_url': 'INVALID HTTP/HTTPS URL',
      'delete_title': 'DELETE TRANSFER',
      'delete_desc': 'Are you sure you want to remove this task from the list?',
      'delete_btn': 'DELETE',
      'cancel_btn': 'CANCEL',
      'pause_btn': 'PAUSE',
      'clipboard_detected': 'CLIPBOARD SIGNAL DETECTED',
      'clipboard_desc': 'DMX detected a URL in your clipboard:',
      'clipboard_ignore': 'IGNORE',
      'clipboard_establish': 'ESTABLISH',
      'onboarding_title_1': 'MAX SPEED ENGINE',
      'onboarding_sub_1': 'Accelerate download speeds with multi-threaded chunking pipelines.',
      'onboarding_title_2': 'SMART CATEGORIES',
      'onboarding_sub_2': 'Auto-organize your files into categorized docks cleanly.',
      'onboarding_title_3': 'TACTILE COCKPIT',
      'onboarding_sub_3': 'Complete control with connection filters, grid styles, and scheduling.',
      'onboarding_start': 'INITIALIZE COCKPIT',
      'onboarding_next': 'NEXT SIGNAL',
      'details_title': 'SIGNAL DETAILS',
      'details_channels': 'CONNECTION CHANNELS (THREADS)',
      'details_active_threads': 'THREADS ACTIVE',
      'details_metadata': 'METADATA INDEX',
      'details_filename': 'FILE NAME',
      'details_url': 'SOURCE URL',
      'details_path': 'SAVE PATH',
      'details_local_file': 'LOCAL FILE',
      'details_size': 'FILE SIZE',
      'details_transferred': 'TRANSFERRED',
      'details_category': 'CATEGORY',
      'details_error': 'LAST ERROR',
      'details_established': 'ESTABLISHED',
      'details_inactive_eta': 'ETA: INACTIVE',
      'details_threads_warning_title': 'RESTRUCTURE CONNECTION CHANNELS?',
      'details_threads_warning_desc': 'Changing connection channels on an active or paused download will delete existing segment files and reset your progress back to 0. Do you want to proceed?',
      'sort_date': 'DATE',
      'sort_status': 'STATUS',
      'search_placeholder': 'Filter signals...',
      'stats_downloading': 'DOWNLOADING',
      'stats_completed': 'COMPLETED',
      'stats_failed': 'FAILED',
      'stats_active': 'ACTIVE',
      'history_empty': 'NO RECENT LOGS RECORDED',
      'history_desc': 'Transferred files index is currently empty.',
      'category_overview': 'STORAGE DISCOVERY OVERVIEW',
      'category_files': 'Files',
      'empty_transmissions': 'NO ACTIVE SIGNALS MONITORING',

      'settings_adv_console': 'ADVANCED POWER CONSOLE',
      'settings_ua': 'CUSTOM USER-AGENT',
      'settings_ua_sub': 'Override default HTTP client headers',
      'settings_proxy': 'ROUTING PROXY TUNNEL',
      'settings_proxy_sub': 'Redirect connection data streams',
      'settings_proxy_address': 'PROXY ADDRESS (IP:PORT)',
      'settings_bypass_ssl': 'TRUST ALL SSL CERTIFICATES',
      'settings_bypass_ssl_sub': 'Bypass SSL validation (WARNING: MITM vulnerability)',
      'settings_reduce_visuals': 'REDUCE VISUAL EFFECTS',
      'settings_reduce_visuals_sub': 'Disable blur and glow effects for better performance',
      'settings_biometric': 'BIOMETRIC APP LOCK',
      'settings_biometric_sub': 'Verify identity before opening cockpit',
      'settings_cleanup': 'AUTO-CLEANUP LOGS',
      'settings_cleanup_sub': 'Purge completed task histories',
      'settings_subfolders': 'CATEGORIZED DIRECTORIES',
      'settings_subfolders_sub': 'Save classified files into subfolders',
      'settings_backup_title': 'SYSTEM BACKUPS',
      'settings_backup_sub': 'Archive and retrieve transmission logs',
      'settings_export': 'EXPORT BACKUP',
      'settings_import': 'IMPORT BACKUP',
    },
    'ar': {
      'app_title': 'DMX',
      'title_transmissions': 'الإشارات',
      'title_categories': 'التصنيفات',
      'title_browser': 'المتصفح',
      'title_history': 'السجل',
      'title_config': 'الإعدادات',
      'config_header': 'DMX // لوحة التكوين',
      'settings_engine_status': 'حالة محرك التنزيل',
      'settings_auto_resume': 'استئناف تلقائي للاتصالات',
      'settings_auto_resume_sub': 'استئناف التنزيلات غير المكتملة عند التشغيل',
      'settings_max_channels': 'أقصى قنوات نشطة',
      'settings_max_channels_sub': 'تحديد التنزيلات المتزامنة',
      'settings_bandwidth': 'النطاق الترددي والواجهات',
      'settings_speed_limit': 'حد السرعة العام',
      'settings_unlimited': 'سرعة غير محدودة',
      'settings_limit_to': 'ميغابايت/ثانية كحد أقصى',
      'settings_wifi_only': 'وضع الواي فاي فقط',
      'settings_wifi_only_sub': 'إيقاف مؤقت للتنزيل على شبكات الهاتف المحمول',
      'settings_cockpit': 'رسوميات لوحة القيادة',
      'settings_glow': 'تفعيل توهج النيون',
      'settings_glow_sub': 'رسم ظلال متوهجة على الأزرار',
      'settings_grid': 'كثافة شبكة الخلفية',
      'settings_grid_sub': 'مستوى الشدة',
      'settings_alerters': 'منبهات الموجات الصوتية',
      'settings_chime': 'رنين التنبيه بالاكتمال',
      'settings_chime_sub': 'تشغيل نغمة عند اكتمال النقل',
      'settings_haptic': 'نبضات الاهتزاز التفاعلية',
      'settings_haptic_sub': 'اهتزاز الجهاز عند الانتقالات الرئيسية',
      'settings_theme': 'النمط البصري للواجهة',
      'settings_theme_sub': 'محرك الوضع المظلم',
      'settings_lang': 'لغة لوحة القيادة',
      'settings_lang_sub': 'اختر لغة واجهة المستخدم',
      'settings_default_threads': 'قنوات الاتصال الافتراضية',
      'settings_default_threads_sub': 'عدد خيوط الأجزاء الافتراضية للتنزيلات الجديدة',
      'settings_about': 'حول DMX',
      'settings_firmware': 'إصدار النظام v2.0.26',
      'settings_about_desc': 'معالج نقل متوازي متعدد الخيوط عالي الكفاءة لشبكات الجوال. مصمم لالتقاط الإشارات منخفضة التأخير.',
      'add_download': 'إنشارة إشارة تنزيل جديدة',
      'add_download_url': 'رابط الإشارة المستهدفة',
      'add_download_name': 'الهوية المحلية (اسم الملف)',
      'add_download_path': 'مسار الحفظ المخصص',
      'add_download_category': 'تصنيف الإشارة',
      'add_download_threads': 'عدد قنوات الاتصال (الخيوط)',
      'add_download_schedule': 'جدولة التنزيل',
      'add_download_schedule_sub': 'تفعيل التنزيل المؤجل',
      'add_download_adv': 'خيارات توجيه متقدمة',
      'add_download_start': 'بدء استقبال الإشارة',
      'add_download_close': 'إغلاق',
      'add_download_empty_url': 'رابط الإشارة مطلوب',
      'add_download_invalid_url': 'الرابط غير صالح',
      'delete_title': 'حذف النقل',
      'delete_desc': 'هل أنت متأكد من حذف هذه المهمة من القائمة؟',
      'delete_btn': 'حذف',
      'cancel_btn': 'إلغاء',
      'pause_btn': 'إيقاف مؤقت',
      'clipboard_detected': 'تم كشف إشارة في الحافظة',
      'clipboard_desc': 'اكتشف DMX رابطًا في حافظتك:',
      'clipboard_ignore': 'تجاهل',
      'clipboard_establish': 'استقبل',
      'onboarding_title_1': 'محرك السرعة القصوى',
      'onboarding_sub_1': 'تسريع التنزيل عن طريق تقسيم الملفات عبر خيوط متعددة.',
      'onboarding_title_2': 'التصنيف الذكي',
      'onboarding_sub_2': 'تنظيم تلقائي لملفاتك داخل تصنيفات محددة بنقاء.',
      'onboarding_title_3': 'لوحة القيادة التفاعلية',
      'onboarding_sub_3': 'تحكم كامل عبر فلاتر التنزيل، أنماط الشبكة، والجدولة.',
      'onboarding_start': 'تهيئة قمرة القيادة',
      'onboarding_next': 'الإشارة التالية',
      'details_title': 'تفاصيل الإشارة',
      'details_channels': 'قنوات الاتصال (الخيوط)',
      'details_active_threads': 'خيوط نشطة',
      'details_metadata': 'مؤشر البيانات التعريفية',
      'details_filename': 'اسم الملف',
      'details_url': 'رابط المصدر',
      'details_path': 'مسار الحفظ',
      'details_local_file': 'الملف المحلي',
      'details_size': 'حجم الملف',
      'details_transferred': 'تم نقله',
      'details_category': 'التصنيف',
      'details_error': 'آخر خطأ',
      'details_established': 'وقت الإنشاء',
      'details_inactive_eta': 'الوقت المقدر: غير نشط',
      'details_threads_warning_title': 'إعادة هيكلة قنوات الاتصال؟',
      'details_threads_warning_desc': 'تغيير قنوات الاتصال على تنزيل نشط أو مؤقت سيؤدي إلى حذف ملفات الأجزاء الحالية وإعادة تعيين تقدمك إلى 0. هل تريد الاستمرار؟',
      'sort_date': 'التاريخ',
      'sort_status': 'الحالة',
      'search_placeholder': 'تصفية الإشارات...',
      'stats_downloading': 'جاري التحميل',
      'stats_completed': 'المكتملة',
      'stats_failed': 'الفاشلة',
      'stats_active': 'النشطة',
      'history_empty': 'لا توجد سجلات مسجلة مؤخرًا',
      'history_desc': 'فهرس الملفات المنقولة فارغ حالياً.',
      'category_overview': 'نظرة عامة على السعة التخزينية',
      'category_files': 'ملفات',
      'empty_transmissions': 'لا توجد إشارات نشطة للمراقبة',

      'settings_adv_console': 'وحدة التحكم المتقدمة',
      'settings_ua': 'عميل مستخدم مخصص (User-Agent)',
      'settings_ua_sub': 'تجاوز ترويسات عميل HTTP الافتراضية',
      'settings_proxy': 'نفق البروكسي الموجه',
      'settings_proxy_sub': 'توجيه تدفق بيانات الاتصال',
      'settings_proxy_address': 'عنوان البروكسي (IP:PORT)',
      'settings_bypass_ssl': 'الوثوق بجميع شهادات SSL',
      'settings_bypass_ssl_sub': 'تجاوز التحقق من الشهادات (تحذير: عرضة للاختراق)',
      'settings_reduce_visuals': 'تقليل التأثيرات البصرية',
      'settings_reduce_visuals_sub': 'تعطيل تأثيرات التمويه والتوهج لتحسين الأداء',
      'settings_biometric': 'قفل التطبيق البصمي',
      'settings_biometric_sub': 'التحقق من الهوية قبل فتح لوحة القيادة',
      'settings_cleanup': 'التنظيف التلقائي للسجلات',
      'settings_cleanup_sub': 'حذف تاريخ المهام المكتملة',
      'settings_subfolders': 'مجلدات التصنيفات الفرعية',
      'settings_subfolders_sub': 'حفظ الملفات المصنفة داخل مجلدات فرعية',
      'settings_backup_title': 'النسخ الاحتياطي للنظام',
      'settings_backup_sub': 'أرشفة واسترجاع سجلات الاتصالات',
      'settings_export': 'تصدير النسخة الاحتياطية',
      'settings_import': 'استيراد النسخة الاحتياطية',
    }
  };

  static String of(BuildContext context, String key) {
    final lang = Provider.of<SettingsProvider>(context, listen: false).languageCode;
    return _translations[lang]?[key] ?? key;
  }

  static String translate(String lang, String key) {
    return _translations[lang]?[key] ?? key;
  }

  static bool isRtl(BuildContext context) {
    return Provider.of<SettingsProvider>(context, listen: false).languageCode == 'ar';
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

  static String translateStatus(BuildContext context, DownloadStatus status, String rawEta) {
    if (!isRtl(context)) return rawEta;
    switch (status) {
      case DownloadStatus.completed:
        return 'مكتمل';
      case DownloadStatus.queued:
        return 'في الانتظار';
      case DownloadStatus.paused:
        return 'موقوف';
      case DownloadStatus.failed:
        return 'فشل';
      default:
        return rawEta
            .replaceAllMapped(RegExp(r'(\d+)\s*h\b'), (m) => '${m[1]}س')
            .replaceAllMapped(RegExp(r'(\d+)\s*m\b'), (m) => '${m[1]}د')
            .replaceAllMapped(RegExp(r'(\d+)\s*s\b'), (m) => '${m[1]}ث')
            .replaceAll(RegExp(r'\bleft\b'), 'متبقي');
    }
  }

  static String translateStatusName(BuildContext context, DownloadStatus status) {
    if (!isRtl(context)) return status.name;
    switch (status) {
      case DownloadStatus.downloading:
        return 'جاري التحميل';
      case DownloadStatus.completed:
        return 'مكتمل';
      case DownloadStatus.paused:
        return 'موقوف مؤقتاً';
      case DownloadStatus.queued:
        return 'في الانتظار';
      case DownloadStatus.failed:
        return 'فشل الاتصال';
    }
  }
}
