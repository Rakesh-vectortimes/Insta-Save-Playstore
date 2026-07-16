import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.fontSize = 26});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text(
      AppConstants.appDisplayName,
      style: GoogleFonts.pacifico(
        fontSize: fontSize,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    this.onInstagramTap,
    this.onMenuTap,
    this.trailing,
  });

  final VoidCallback? onInstagramTap;
  final VoidCallback? onMenuTap;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          const AppLogo(),
          const Spacer(),
          if (trailing != null) ...trailing!,
          IconButton(
            onPressed: onInstagramTap ??
                () {},
            icon: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                gradient: AppColors.instagramGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.camera_alt, color: Colors.white, size: 14),
            ),
          ),
          IconButton(
            onPressed: onMenuTap,
            icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}
