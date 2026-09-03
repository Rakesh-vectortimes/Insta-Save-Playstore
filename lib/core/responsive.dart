import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Layout helpers for phones, 7" tablets, and 10" tablets.
///
/// Breakpoints follow Material 3 window sizes:
/// - compact: shortest side < 600 (phones)
/// - medium: 600–839 (typical 7" tablet)
/// - expanded: 840+ (typical 10" tablet)
class AppBreakpoints {
  static const double tablet = 600;
  static const double largeTablet = 840;

  static Size sizeOf(BuildContext context) => MediaQuery.sizeOf(context);

  static double shortestSideOf(BuildContext context) =>
      sizeOf(context).shortestSide;

  static bool isTablet(BuildContext context) =>
      shortestSideOf(context) >= tablet;

  static bool isLargeTablet(BuildContext context) =>
      shortestSideOf(context) >= largeTablet;

  static bool useNavigationRail(BuildContext context) => isTablet(context);

  static double contentMaxWidth(BuildContext context) {
    if (isLargeTablet(context)) return 1100;
    if (isTablet(context)) return 840;
    return double.infinity;
  }

  static double previewMaxWidth(BuildContext context) {
    if (isLargeTablet(context)) return 480;
    if (isTablet(context)) return 420;
    return double.infinity;
  }

  static int gridCount(
    BuildContext context, {
    int phone = 2,
  }) {
    final width = sizeOf(context).width;
    if (width >= 1200) return phone + 3;
    if (width >= 900) return phone + 2;
    if (width >= 600) return phone + 1;
    return phone;
  }

  static EdgeInsets pagePadding(BuildContext context) {
    if (isLargeTablet(context)) {
      return const EdgeInsets.fromLTRB(32, 8, 32, 24);
    }
    if (isTablet(context)) {
      return const EdgeInsets.fromLTRB(24, 8, 24, 20);
    }
    return const EdgeInsets.fromLTRB(16, 8, 16, 16);
  }

  static double dialogMaxWidth(BuildContext context) {
    if (isTablet(context)) return 480;
    return math.min(sizeOf(context).width - 48, 400);
  }
}

/// Centers [child] and caps width on tablets so phone layouts don't stretch.
class AdaptiveBody extends StatelessWidget {
  const AdaptiveBody({
    super.key,
    required this.child,
    this.maxWidth,
  });

  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cap = maxWidth ?? AppBreakpoints.contentMaxWidth(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = cap.isFinite
            ? math.min(constraints.maxWidth, cap)
            : constraints.maxWidth;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : null,
            child: child,
          ),
        );
      },
    );
  }
}
