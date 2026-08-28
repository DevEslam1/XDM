/// Represents a subscription plan available for purchase.
class SubscriptionPlan {
  final String id;
  final String productId;
  final String displayName;
  final String description;
  final String price;
  final String period;
  final bool isPopular;

  const SubscriptionPlan({
    required this.id,
    required this.productId,
    required this.displayName,
    required this.description,
    required this.price,
    required this.period,
    this.isPopular = false,
  });

  static const monthly = SubscriptionPlan(
    id: 'monthly',
    productId: 'com.xdm.premium.monthly',
    displayName: 'Monthly',
    description: 'Billed monthly',
    price: '\$4.99',
    period: '/month',
  );

  static const annual = SubscriptionPlan(
    id: 'annual',
    productId: 'com.xdm.premium.annual',
    displayName: 'Annual',
    description: 'Billed annually — save 40%',
    price: '\$29.99',
    period: '/year',
    isPopular: true,
  );

  static const lifetime = SubscriptionPlan(
    id: 'lifetime',
    productId: 'com.xdm.premium.lifetime',
    displayName: 'Lifetime',
    description: 'One-time purchase — yours forever',
    price: '\$59.99',
    period: '',
  );

  static const all = [monthly, annual, lifetime];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubscriptionPlan &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SubscriptionPlan($id, $price$period)';
}
