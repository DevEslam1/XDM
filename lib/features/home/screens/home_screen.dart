import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/app_theme.dart';
import '../../../core/utils/localization.dart';
import '../../downloads/provider/download_provider.dart';
import '../../downloads/widgets/download_card.dart';
import '../../downloads/widgets/download_stats_panel.dart';
import '../../downloads/widgets/filter_chips_bar.dart';
import '../../settings/provider/settings_provider.dart';
import '../../../shared/widgets/geometric_grid_background.dart';
import '../../../shared/widgets/dmx_backdrop_filter.dart';
import '../../../shared/widgets/themed_snackbar.dart';
import '../../add_download/screens/add_screen.dart';
import '../../../core/utils/haptic_helper.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with HapticHelper {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<DownloadProvider>(context);
    final settings = Provider.of<SettingsProvider>(context);
    final tasks = provider.filteredTasks;
    final isDark = settings.isDarkMode;
    final textClr = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final accentClr = isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet;

    return GeometricGridBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: ClipRect(
            child: DmxBackdropFilter(
              sigmaX: 12,
              sigmaY: 12,
              child: Container(
                color: (isDark ? AppTheme.surface : AppTheme.lightSurface).withValues(alpha: 0.5),
              ),
            ),
          ),
          title: _isSearching
              ? Container(
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.glassBg : AppTheme.lightGlassBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                      width: 0.8,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: TextStyle(
                      color: textClr,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      hintText: L10n.of(context, 'search_placeholder').toUpperCase(),
                      hintStyle: TextStyle(
                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                        fontSize: 14,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (val) => provider.setSearchQuery(val),
                  ),
                )
              : Text(
                  'XDM',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: textClr,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    fontSize: 18,
                  ),
                ),
          actions: [
            IconButton(
              icon: Icon(
                _isSearching ? Icons.close : Icons.search,
                color: textClr,
              ),
              onPressed: () {
                triggerHaptic(settings);
                setState(() {
                  if (_isSearching) {
                    _isSearching = false;
                    _searchController.clear();
                    provider.setSearchQuery('');
                  } else {
                    _isSearching = true;
                  }
                });
              },
            ),
            if (!_isSearching)
              PopupMenuButton<SortOption>(
                icon: Icon(Icons.sort_rounded, color: textClr),
                tooltip: 'SORT CHANNELS',
                color: isDark ? AppTheme.surface : AppTheme.lightSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder,
                    width: 0.6,
                  ),
                ),
                onSelected: (option) {
                  triggerHaptic(settings);
                  if (provider.sortOption == option) {
                    provider.toggleSortDirection();
                  } else {
                    provider.setSortOption(option);
                  }
                },
                itemBuilder: (context) => [
                  _buildSortMenuItem(
                    option: SortOption.dateAdded,
                    label: L10n.of(context, 'sort_date'), // Date reference
                    currentOption: provider.sortOption,
                    ascending: provider.sortAscending,
                    settings: settings,
                  ),
                  _buildSortMenuItem(
                    option: SortOption.fileSize,
                    label: L10n.of(context, 'details_size'),
                    currentOption: provider.sortOption,
                    ascending: provider.sortAscending,
                    settings: settings,
                  ),
                  _buildSortMenuItem(
                    option: SortOption.fileName,
                    label: L10n.of(context, 'details_filename'),
                    currentOption: provider.sortOption,
                    ascending: provider.sortAscending,
                    settings: settings,
                  ),
                  _buildSortMenuItem(
                    option: SortOption.status,
                    label: L10n.of(context, 'sort_status'), // Status reference
                    currentOption: provider.sortOption,
                    ascending: provider.sortAscending,
                    settings: settings,
                  ),
                ],
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Statistics
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: DownloadStatsPanel(),
              ),
              const SizedBox(height: 8),

              // Filter Chips
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: FilterChipsBar(),
              ),
              const SizedBox(height: 16),

              // Title "CHANNEL OVERVIEW"
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      L10n.of(context, 'details_channels'),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
                        fontSize: 10,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${tasks.length} ${L10n.isRtl(context) ? 'إشارات' : 'SIGNALS'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Download Tasks list with Pull-to-Refresh
              Expanded(
                child: tasks.isEmpty
                    ? _buildEmptyState(context)
                    : RefreshIndicator(
                        color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                        backgroundColor: isDark ? AppTheme.surface : AppTheme.lightSurface,
                        onRefresh: () async {
                          triggerHaptic(settings);
                          await provider.load();
                          if (context.mounted) {
                            ThemedSnackbar.show(
                              context,
                              message: L10n.isRtl(context) ? 'تم إعادة تحميل سجلات الاتصال' : 'Transmission logs reloaded',
                              color: isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue,
                              icon: Icons.sync,
                              isDarkMode: isDark,
                            );
                          }
                        },
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                          itemCount: tasks.length,
                          itemBuilder: (context, index) {
                            return DownloadCard(task: tasks[index]);
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
        floatingActionButton: Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: accentClr.withValues(alpha: 0.3),
                  blurRadius: 16.0,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: FloatingActionButton(
              backgroundColor: accentClr,
              foregroundColor: isDark ? AppTheme.background : AppTheme.lightBackground,
              shape: const CircleBorder(
                side: BorderSide(color: Colors.white24, width: 0.8),
              ),
              child: const Icon(Icons.add, size: 28),
              onPressed: () {
                triggerHaptic(settings);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AddScreen()),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final isDark = settings.isDarkMode;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? AppTheme.glassBg : AppTheme.lightGlassBg,
              border: Border.all(color: isDark ? AppTheme.glassBorder : AppTheme.lightGlassBorder, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: (isDark ? AppTheme.neonViolet : AppTheme.lightNeonViolet).withValues(alpha: 0.06),
                  blurRadius: 20.0,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Icon(
              Icons.portable_wifi_off_outlined,
              size: 40,
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            L10n.of(context, 'empty_transmissions'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary,
              letterSpacing: 1.0,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            L10n.isRtl(context) ? 'أدخل رابط الإشارة لبدء الاتصال.' : 'Insert a URL signal to establish connection.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isDark ? AppTheme.textMuted : AppTheme.lightTextMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<SortOption> _buildSortMenuItem({
    required SortOption option,
    required String label,
    required SortOption currentOption,
    required bool ascending,
    required SettingsProvider settings,
  }) {
    final isSelected = currentOption == option;
    final isDark = settings.isDarkMode;
    final activeColor = isDark ? AppTheme.neonBlue : AppTheme.lightNeonBlue;
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;

    return PopupMenuItem<SortOption>(
      value: option,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: isSelected ? activeColor : textColor,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 12,
            ),
          ),
          if (isSelected)
            Icon(
              ascending ? Icons.arrow_upward : Icons.arrow_downward,
              color: activeColor,
              size: 16,
            ),
        ],
      ),
    );
  }
}
