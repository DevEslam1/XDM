import 'package:flutter/material.dart';

enum PageTransitionType { slideRight, slideUp }

class PremiumPageRoute<T> extends PageRouteBuilder<T> {
  final Widget child;
  final PageTransitionType type;

  PremiumPageRoute({required this.child, this.type = PageTransitionType.slideRight})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (MediaQuery.of(context).disableAnimations) return child;

            final curve = Curves.easeOutCubic;

            final begin = type == PageTransitionType.slideUp
                ? const Offset(0.0, 0.08)
                : const Offset(0.08, 0.0);
            const end = Offset.zero;

            var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
            var offsetAnimation = animation.drive(tween);

            var fadeTween = Tween<double>(begin: 0.0, end: 1.0).chain(CurveTween(curve: curve));
            var fadeAnimation = animation.drive(fadeTween);

            var scaleTween = Tween<double>(begin: 0.96, end: 1.0).chain(CurveTween(curve: curve));
            var scaleAnimation = animation.drive(scaleTween);

            return FadeTransition(
              opacity: fadeAnimation,
              child: ScaleTransition(
                scale: scaleAnimation,
                child: SlideTransition(
                  position: offsetAnimation,
                  child: child,
                ),
              ),
            );
          },
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 250),
        );
}
