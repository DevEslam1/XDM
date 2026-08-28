import 'subscription_status.dart';

/// Defines feature limits and capabilities for each subscription tier.
class SubscriptionTier {
  final String id;
  final String displayName;
  final int maxConcurrentDownloads;
  final int maxDownloadThreads;
  final bool torrentSupport;
  final bool adRemoval;
  final bool prioritySupport;
  final bool unlimitedSpeed;

  const SubscriptionTier._({
    required this.id,
    required this.displayName,
    required this.maxConcurrentDownloads,
    required this.maxDownloadThreads,
    required this.torrentSupport,
    required this.adRemoval,
    required this.prioritySupport,
    required this.unlimitedSpeed,
  });

  /// Free tier — limited but functional.
  static const free = SubscriptionTier._(
    id: 'free',
    displayName: 'Free',
    maxConcurrentDownloads: 3,
    maxDownloadThreads: 4,
    torrentSupport: false,
    adRemoval: false,
    prioritySupport: false,
    unlimitedSpeed: false,
  );

  /// Premium tier — everything unlocked.
  static const premium = SubscriptionTier._(
    id: 'premium',
    displayName: 'Premium',
    maxConcurrentDownloads: 0, // 0 = unlimited
    maxDownloadThreads: 0, // 0 = unlimited
    torrentSupport: true,
    adRemoval: true,
    prioritySupport: true,
    unlimitedSpeed: true,
  );

  /// Returns the appropriate tier for the given subscription status.
  static SubscriptionTier forStatus(SubscriptionStatus status) {
    switch (status) {
      case SubscriptionStatus.active:
      case SubscriptionStatus.trial:
        return premium;
      case SubscriptionStatus.free:
      case SubscriptionStatus.expired:
      case SubscriptionStatus.cancelled:
      case SubscriptionStatus.unknown:
        return free;
    }
  }

  bool get isPremium => id == 'premium';
  bool get isFree => id == 'free';

  /// Whether the user has reached the concurrent download limit.
  bool hasReachedDownloadLimit(int activeDownloadCount) {
    if (maxConcurrentDownloads == 0) return false; // unlimited
    return activeDownloadCount >= maxConcurrentDownloads;
  }

  /// Max allowed download threads, clamped to reasonable bounds.
  int effectiveThreadCount(int requested) {
    if (maxDownloadThreads == 0) return requested; // unlimited
    return requested.clamp(1, maxDownloadThreads);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubscriptionTier &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SubscriptionTier($id)';
}
