import 'subscription_tier.dart';

/// Describes a specific feature entitlement with its status for the current tier.
class Entitlement {
  final String key;
  final String displayName;
  final bool isEnabled;
  final String? reason;

  const Entitlement._({
    required this.key,
    required this.displayName,
    required this.isEnabled,
    this.reason,
  });

  /// All available entitlements for the given tier.
  static List<Entitlement> forTier(SubscriptionTier tier) => [
        Entitlement._(
          key: 'unlimited_downloads',
          displayName: 'Unlimited Concurrent Downloads',
          isEnabled: tier.maxConcurrentDownloads == 0,
          reason: tier.maxConcurrentDownloads == 0
              ? null
              : 'Upgrade to Premium for unlimited downloads',
        ),
        Entitlement._(
          key: 'high_thread_count',
          displayName: 'High Thread Count (8+)',
          isEnabled:
              tier.maxDownloadThreads == 0 || tier.maxDownloadThreads >= 8,
          reason: tier.maxDownloadThreads >= 8 || tier.maxDownloadThreads == 0
              ? null
              : 'Free tier limited to ${tier.maxDownloadThreads} threads',
        ),
        Entitlement._(
          key: 'torrent_support',
          displayName: 'Torrent Downloads',
          isEnabled: tier.torrentSupport,
          reason: tier.torrentSupport
              ? null
              : 'Upgrade to Premium for torrent support',
        ),
        Entitlement._(
          key: 'ad_removal',
          displayName: 'Ad-Free Experience',
          isEnabled: tier.adRemoval,
          reason: tier.adRemoval ? null : 'Upgrade to Premium to remove ads',
        ),
        Entitlement._(
          key: 'priority_support',
          displayName: 'Priority Support',
          isEnabled: tier.prioritySupport,
          reason: tier.prioritySupport
              ? null
              : 'Upgrade to Premium for priority support',
        ),
        Entitlement._(
          key: 'unlimited_speed',
          displayName: 'Unlimited Download Speed',
          isEnabled: tier.unlimitedSpeed,
          reason: tier.unlimitedSpeed
              ? null
              : 'Upgrade to Premium for unlimited speed',
        ),
      ];

  /// Check if a specific entitlement is enabled.
  static bool isEntitled(SubscriptionTier tier, String entitlementKey) {
    return forTier(tier).any((e) => e.key == entitlementKey && e.isEnabled);
  }

  @override
  String toString() => 'Entitlement($key, enabled=$isEnabled, reason=$reason)';
}
