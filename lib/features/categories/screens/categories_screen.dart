import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../../shared/design/dmx_design.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../downloads/provider/download_provider.dart';
import '../../settings/provider/settings_provider.dart';
import 'category_detail_screen.dart';

class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final counts = context
        .select<DownloadProvider, Map<String, int>>((p) => p.categoryCounts);
    final sizes = context
        .select<DownloadProvider, Map<String, double>>((p) => p.categorySizes);
    final settings = Provider.of<SettingsProvider>(context);
    final isDark = settings.isDarkMode;
    final isRtl = L10n.isRtl(context);
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final secClr =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;

    // Define category presentation details
    final List<Map<String, dynamic>> categoryCards = [
      {
        'name': 'Video',
        'icon': Icons.movie_outlined,
        'color': isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
        'description': 'MP4, MKV, AVI, MOV',
      },
      {
        'name': 'Audio',
        'icon': Icons.audiotrack_outlined,
        'color': isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet,
        'description': 'MP3, WAV, FLAC, AAC',
      },
      {
        'name': 'Document',
        'icon': Icons.description_outlined,
        'color': isDark ? AppTheme.neonGreen : AppTheme.lightNeonGreen,
        'description': 'PDF, DOCX, XLSX, TXT',
      },
      {
        'name': 'Archive',
        'icon': Icons.folder_zip_outlined,
        'color': isDark ? AppTheme.neonAmber : AppTheme.lightNeonAmber,
        'description': 'ZIP, RAR, 7Z, TAR',
      },
      {
        'name': 'APK',
        'icon': Icons.android_outlined,
        'color': const Color(0xFFF15BB5),
        'description': isRtl ? 'ملفات تطبيقات أندرويد' : 'Android App Packages',
      },
      {
        'name': 'Other',
        'icon': Icons.insert_drive_file_outlined,
        'color': isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
        'description': isRtl ? 'ملفات بيانات متنوعة' : 'Miscellaneous Data',
      },
    ];

    // Compute total size
    final totalSizeMb = sizes.values.fold(0.0, (sum, val) => sum + val);

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: isDark
              ? (settings.isAmoledMode
                  ? AppTheme.amoledBackground
                  : Colors.transparent)
              : Colors.transparent,
          flexibleSpace: settings.isAmoledMode
              ? null
              : ClipRect(
                  child: DmxBackdropFilter(
                    sigmaX: 12,
                    sigmaY: 12,
                    child: Container(
                      color: (isDark ? AppTheme.surface : AppTheme.lightSurface)
                          .withValues(alpha: 0.5),
                    ),
                  ),
                ),
          title: Text(
            'XDM',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: textClr,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  fontSize: 16,
                ),
          ),
          automaticallyImplyLeading: false,
        ),
        body: Directionality(
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header description
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 10.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L10n.of(context, 'category_overview'),
                        style:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: secClr,
                                  fontSize: 10,
                                  letterSpacing: 1.0,
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isRtl
                            ? 'عرض تفصيلي للملفات المحملة مقسمة حسب نوع الملف.'
                            : 'Overview of downloaded content structured by MIME-type.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: mutedClr,
                              fontSize: 11,
                            ),
                      ),
                    ],
                  ),
                ),

                // Donut PieChart Analytics Panel
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 8.0),
                  child: _buildDonutChartCard(
                      context, categoryCards, sizes, totalSizeMb, settings),
                ),
                const SizedBox(height: 10),

                // Categories Grid
                Expanded(
                  child: Builder(builder: (context) {
                    final fontScale =
                        MediaQuery.textScalerOf(context).scale(1.0);
                    return GridView.builder(
                      padding: const EdgeInsets.all(16.0),
                      physics: const BouncingScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        mainAxisExtent: (160 * fontScale).clamp(160.0, 240.0),
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: categoryCards.length,
                      itemBuilder: (context, index) {
                        final card = categoryCards[index];
                        final String name = card['name'];
                        final IconData icon = card['icon'];
                        final Color color = card['color'];
                        final String desc = card['description'];

                        final count = counts[name] ?? 0;
                        final sizeMb = sizes[name] ?? 0.0;

                        // Format size
                        String sizeText;
                        if (sizeMb >= 1024) {
                          sizeText = '${(sizeMb / 1024).toStringAsFixed(2)} GB';
                        } else {
                          sizeText = '${sizeMb.toStringAsFixed(1)} MB';
                        }

                        return GestureDetector(
                          onTap: () {
                            if (settings.vibration) {
                              HapticFeedback.lightImpact();
                            }
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                pageBuilder:
                                    (ctx, animation, secondaryAnimation) =>
                                        CategoryDetailScreen(
                                  categoryName: name,
                                  categoryColor: color,
                                  categoryIcon: icon,
                                ),
                                transitionsBuilder: (ctx, animation,
                                    secondaryAnimation, child) {
                                  return FadeTransition(
                                    opacity: CurvedAnimation(
                                      parent: animation,
                                      curve: Curves.easeOut,
                                    ),
                                    child: SlideTransition(
                                      position: Tween(
                                        begin: const Offset(0.05, 0),
                                        end: Offset.zero,
                                      ).animate(CurvedAnimation(
                                        parent: animation,
                                        curve: AppTheme.motionCurve,
                                      )),
                                      child: child,
                                    ),
                                  );
                                },
                                transitionDuration: AppTheme.motionBase,
                              ),
                            );
                          },
                          child: DmxCardShell(
                            accent: color,
                            radius: 20,
                            showRail: false,
                            child: Padding(
                              padding: const EdgeInsets.all(14.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: color.withValues(
                                            alpha: 0.08,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          icon,
                                          color: color,
                                          size: 22,
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? AppTheme.glassBg
                                              : AppTheme.lightGlassBg,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: isDark
                                                ? AppTheme.glassBorder
                                                : AppTheme.lightGlassBorder,
                                            width: 0.6,
                                          ),
                                        ),
                                        child: Text(
                                          '$count ${isRtl ? 'عناصر' : 'ITEMS'}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: textClr,
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Text(
                                    _translateCategoryName(context, name)
                                        .toUpperCase(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.8,
                                          color: textClr,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    desc,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          fontSize: 9,
                                          color: mutedClr,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    sizeText,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          fontSize: 13,
                                          color: color,
                                          fontWeight: FontWeight.bold,
                                          shadows: isDark
                                              ? [
                                                  Shadow(
                                                    color: color.withValues(
                                                      alpha: 0.25,
                                                    ),
                                                    blurRadius: 4.0,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDonutChartCard(
    BuildContext context,
    List<Map<String, dynamic>> categoryCards,
    Map<String, double> sizes,
    double totalSizeMb,
    SettingsProvider settings,
  ) {
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final mutedClr = isDark ? AppTheme.textMuted : AppTheme.lightTextMuted;
    final isRtl = L10n.isRtl(context);

    // Format total size
    String totalSizeText;
    if (totalSizeMb >= 1024) {
      totalSizeText = '${(totalSizeMb / 1024).toStringAsFixed(2)} GB';
    } else {
      totalSizeText = '${totalSizeMb.toStringAsFixed(1)} MB';
    }

    final hasNoData = totalSizeMb == 0.0;

    // Create sections
    final List<PieChartSectionData> sections = hasNoData
        ? [
            PieChartSectionData(
              color: isDark ? AppTheme.border : AppTheme.lightBorder,
              value: 1.0,
              radius: 16,
              title: '',
            )
          ]
        : categoryCards
            .map((card) {
              final String name = card['name'];
              final Color color = card['color'];
              final sizeMb = sizes[name] ?? 0.0;
              final percentage =
                  totalSizeMb > 0 ? (sizeMb / totalSizeMb) * 100 : 0.0;

              return PieChartSectionData(
                color: color,
                value: sizeMb,
                radius: 16,
                title:
                    percentage >= 10 ? '${percentage.toStringAsFixed(0)}%' : '',
                titleStyle: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              );
            })
            .where((section) => section.value > 0)
            .toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: DmxBackdropFilter(
        sigmaX: 10,
        sigmaY: 10,
        child: Container(
          width: double.infinity,
          height: 120,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration:
              AppTheme.glassDecoration(borderRadius: 20, isDark: isDark),
          child: Row(
            children: [
              // 1. Donut PieChart
              SizedBox(
                width: 110,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sections: sections,
                        centerSpaceRadius: 28,
                        sectionsSpace: 2.5,
                      ),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isRtl ? 'الإجمالي' : 'TOTAL',
                            style: TextStyle(
                              color: mutedClr,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            totalSizeText,
                            style: TextStyle(
                              color: textClr,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // 2. Legend / List summary of top categories sizes
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: (() {
                    final sortedCards =
                        List<Map<String, dynamic>>.from(categoryCards)
                          ..sort((a, b) {
                            final sizeA = sizes[a['name']] ?? 0.0;
                            final sizeB = sizes[b['name']] ?? 0.0;
                            return sizeB.compareTo(sizeA);
                          });
                    return sortedCards.take(3);
                  })()
                      .map((card) {
                    final String name = card['name'];
                    final Color color = card['color'];
                    final sizeMb = sizes[name] ?? 0.0;
                    final String sizeText = sizeMb >= 1024
                        ? '${(sizeMb / 1024).toStringAsFixed(1)}G'
                        : '${sizeMb.toStringAsFixed(0)}M';

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _translateCategoryName(context, name),
                              style: TextStyle(
                                color: textClr,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            sizeText,
                            style: TextStyle(
                              color: color,
                              fontSize: 10,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _translateCategoryName(BuildContext context, String name) {
    if (!L10n.isRtl(context)) return name;
    switch (name) {
      case 'Video':
        return 'الفيديو';
      case 'Audio':
        return 'الصوت';
      case 'Document':
        return 'المستندات';
      case 'Archive':
        return 'الأرشيف';
      case 'APK':
        return 'التطبيقات';
      default:
        return 'أخرى';
    }
  }
}
