/// Represents the current subscription state of the user.
enum SubscriptionStatus {
  /// No active subscription — free tier.
  free,

  /// Active paid subscription.
  active,

  /// Subscription was active but has expired.
  expired,

  /// Currently in a free trial period.
  trial,

  /// Subscription was cancelled but remains active until period end.
  cancelled,

  /// Subscription status could not be determined (e.g., offline).
  unknown;

  bool get isPremium =>
      this == SubscriptionStatus.active || this == SubscriptionStatus.trial;

  bool get isFree => this == SubscriptionStatus.free;

  bool get canDownload => this != SubscriptionStatus.unknown;

  /// Grace period after expiry where downloads in-progress are allowed.
  bool get inGracePeriod => this == SubscriptionStatus.expired;
}
