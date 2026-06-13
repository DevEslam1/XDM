import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/settings/provider/settings_provider.dart';
import '../../features/downloads/models/download_task.dart';

class L10n {
  static const Map<String, Map<String, String>> _translations = {
    'en': {
      'app_title': 'XDM',
      'title_transmissions': 'DOWNLOADS',
      'title_categories': 'CATEGORIES',
      'title_browser': 'BROWSER',
      'title_history': 'HISTORY',
      'title_config': 'SETTINGS',
      'config_header': 'SETTINGS',
      'settings_engine_status': 'DOWNLOAD ENGINE STATUS',
      'settings_auto_resume': 'AUTO-RESUME DOWNLOADS',
      'settings_auto_resume_sub': 'Resume unfinished downloads on startup',
      'settings_max_channels': 'MAX ACTIVE DOWNLOADS',
      'settings_max_channels_sub': 'Limit concurrent downloads',
      'settings_bandwidth': 'SPEED & CONNECTIONS',
      'settings_speed_limit': 'GLOBAL SPEED LIMIT',
      'settings_unlimited': 'UNLIMITED BANDWIDTH',
      'settings_limit_to': 'MB/S MAXIMUM',
      'settings_wifi_only': 'WIFI-ONLY MODE',
      'settings_wifi_only_sub': 'Pause downloads on mobile networks',
      'settings_cockpit': 'INTERFACE STYLING',
      'settings_glow': 'ENABLE NEON GLOW ACCENTS',
      'settings_glow_sub': 'Draw glowing drop shadows on buttons',
      'settings_grid': 'BACKGROUND GRID DENSITY',
      'settings_grid_sub': 'INTENSITY',
      'settings_alerters': 'ALERT SOUNDS',
      'settings_chime': 'COMPLETION AUDIBLE CHIME',
      'settings_chime_sub': 'Play audio ping when download completes',
      'settings_haptic': 'HAPTIC FEEDBACK PULSES',
      'settings_haptic_sub': 'Vibrate device on key transitions',
      'settings_theme': 'VISUAL MODE STYLE',
      'settings_theme_sub': 'DARK MODE ENGINE',
      'settings_lang': 'LANGUAGE',
      'settings_lang_sub': 'Select interface localization',
      'settings_default_threads': 'DEFAULT CONNECTIONS (THREADS)',
      'settings_default_threads_sub':
          'Default connection threads count for new downloads',
      'settings_about': 'ABOUT XDM',
      'settings_firmware': 'VERSION 2.0.26',
      'settings_about_desc':
          'High-efficiency parallel multithreaded download processor.',
      'add_download': 'ADD NEW DOWNLOAD',
      'add_download_url': 'DOWNLOAD URL / LINK',
      'add_download_name': 'FILE NAME (OPTIONAL)',
      'add_download_path': 'SAVE LOCATION',
      'add_download_category': 'CATEGORY',
      'add_download_threads': 'CONNECTIONS (THREADS)',
      'add_download_schedule': 'SCHEDULE DOWNLOAD',
      'add_download_schedule_sub': 'Enable delayed activation',
      'add_download_adv': 'ADVANCED OPTIONS',
      'add_download_start': 'START DOWNLOAD',
      'add_download_close': 'CLOSE',
      'add_download_empty_url': 'URL LINK REQUIRED',
      'add_download_invalid_url': 'INVALID HTTP/HTTPS URL',
      'delete_title': 'DELETE DOWNLOAD',
      'delete_desc': 'Are you sure you want to remove this download from the list?',
      'delete_btn': 'DELETE',
      'cancel_btn': 'CANCEL',
      'delete_files_label': 'Delete downloaded files/parts from disk',
      'seeds': 'Seeds',
      'peers': 'Peers',
      'pause_btn': 'PAUSE',
      'clipboard_detected': 'CLIPBOARD LINK DETECTED',
      'clipboard_desc': 'XDM detected a download link in your clipboard:',
      'clipboard_ignore': 'IGNORE',
      'clipboard_establish': 'DOWNLOAD',
      'onboarding_title_1': 'MAX SPEED ENGINE',
      'onboarding_sub_1':
          'Accelerate download speeds with multi-threaded chunking pipelines.',
      'onboarding_title_2': 'SMART CATEGORIES',
      'onboarding_sub_2':
          'Auto-organize your files into categorized folders cleanly.',
      'onboarding_title_3': 'EASY MANAGEMENT',
      'onboarding_sub_3':
          'Complete control with connection settings, grid styles, and scheduling.',
      'onboarding_start': 'GET STARTED',
      'onboarding_next': 'NEXT',
      'details_title': 'DOWNLOAD DETAILS',
      'details_channels': 'CONNECTION THREADS',
      'details_active_threads': 'THREADS ACTIVE',
      'details_metadata': 'FILE INFORMATION',
      'details_filename': 'FILE NAME',
      'details_url': 'SOURCE URL',
      'details_path': 'SAVE PATH',
      'details_local_file': 'LOCAL FILE',
      'details_size': 'FILE SIZE',
      'details_transferred': 'TRANSFERRED',
      'details_category': 'CATEGORY',
      'details_error': 'LAST ERROR',
      'details_established': 'ADDED ON',
      'details_inactive_eta': 'ETA: INACTIVE',
      'details_threads_warning_title': 'RESTRUCTURE CONNECTION THREADS?',
      'details_threads_warning_desc':
          'Changing connection threads on an active or paused download will reset progress. Do you want to proceed?',
      'sort_date': 'DATE',
      'sort_status': 'STATUS',
      'search_placeholder': 'Filter downloads...',
      'stats_downloading': 'DOWNLOADING',
      'stats_completed': 'COMPLETED',
      'stats_failed': 'FAILED',
      'stats_active': 'ACTIVE',
      'history_empty': 'NO COMPLETED DOWNLOADS',
      'history_desc': 'Transferred files index is currently empty.',
      'category_overview': 'STORAGE ANALYTICS',
      'category_files': 'Files',
      'empty_transmissions': 'NO ACTIVE DOWNLOADS',

      'settings_adv_console': 'ADVANCED SETTINGS',
      'settings_ua': 'CUSTOM USER-AGENT',
      'settings_ua_sub': 'Override default HTTP client headers',
      'settings_proxy': 'ROUTING PROXY TUNNEL',
      'settings_proxy_sub': 'Redirect connection data streams',
      'settings_proxy_address': 'PROXY ADDRESS (IP:PORT)',
      'settings_bypass_ssl': 'TRUST ALL SSL CERTIFICATES',
      'settings_bypass_ssl_sub':
          'Bypass SSL validation (WARNING: MITM vulnerability)',
      'settings_reduce_visuals': 'REDUCE VISUAL EFFECTS',
      'settings_reduce_visuals_sub':
          'Disable blur and glow effects for better performance',
      'settings_classic_ui': 'CLASSIC UI MODE',
      'settings_classic_ui_sub':
          'Switch to a flat native UI design styling',
      'settings_biometric': 'BIOMETRIC APP LOCK',
      'settings_biometric_sub': 'Verify identity before opening app',
      'settings_cleanup': 'AUTO-CLEANUP LOGS',
      'settings_cleanup_sub': 'Purge completed task histories',
      'settings_subfolders': 'CATEGORIZED DIRECTORIES',
      'settings_subfolders_sub': 'Save classified files into subfolders',
      'settings_backup_title': 'SYSTEM BACKUPS',
      'settings_backup_sub': 'Archive and retrieve download logs',
      'settings_export': 'EXPORT BACKUP',
      'settings_import': 'IMPORT BACKUP',
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
      'settings_firmware': 'الإصدار v2.0.26',
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
      'settings_biometric': 'قفل التطبيق البصمي',
      'settings_biometric_sub': 'التحقق من الهوية قبل فتح التطبيق',
      'settings_cleanup': 'التنظيف التلقائي للسجلات',
      'settings_cleanup_sub': 'حذف تاريخ المهام المكتملة',
      'settings_subfolders': 'مجلدات التصنيفات الفرعية',
      'settings_subfolders_sub': 'حفظ الملفات المصنفة داخل مجلدات فرعية',
      'settings_backup_title': 'النسخ الاحتياطي للنظام',
      'settings_backup_sub': 'أرشفة واسترجاع سجلات التنزيل',
      'settings_export': 'تصدير النسخة الاحتياطية',
      'settings_import': 'استيراد النسخة الاحتياطية',
    },
  };

  static String of(BuildContext context, String key) {
    final lang = Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).languageCode;
    return _translations[lang]?[key] ?? key;
  }

  static String translate(String lang, String key) {
    return _translations[lang]?[key] ?? key;
  }

  static bool isRtl(BuildContext context) {
    return Provider.of<SettingsProvider>(context, listen: false).languageCode ==
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
      default:
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
