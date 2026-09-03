import 'package:flutter/material.dart';

class AppConstants {
  static const String apiBaseUrl = 'https://api.dlreels.com';

  static const String appName = 'Video Downloader - Save Story';
  static const String appDisplayName = 'Video Downloader - Save Story';

  static const String storyLoginHint =
      'Story downloads work when you\'re logged into Instagram in the device browser.';

  static const String storyNotSupportedMessage =
      'Stories require login and aren\'t supported. We only support public posts and reels.';

  static const String invalidUrlMessage =
      'Please paste a valid Instagram link';

  static const String splashHeadline = 'No Login Required';
  static const String splashSubtitle =
      'Download Reels, Posts & Stories in HD';
}

class AppColors {
  // Dark theme (primary UI)
  static const Color darkBackground = Color(0xFF000000);
  static const Color darkSurface = Color(0xFF1A1A1A);
  static const Color darkCard = Color(0xFF2A2A2A);
  static const Color darkInput = Color(0xFF2C2C2C);
  static const Color darkBorder = Color(0xFF3A3A3A);

  static const Color primary = Color(0xFFE91E63);
  static const Color primaryDark = Color(0xFFC13584);
  static const Color accent = Color(0xFFFF4D67);
  static const Color accentOrange = Color(0xFFFF8C00);
  static const Color accentPurple = Color(0xFF8E44AD);

  // Splash (light)
  static const Color splashBackground = Color(0xFFFFFFFF);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF9E9E9E);
  static const Color textMuted = Color(0xFF6B6B6B);
  static const Color error = Color(0xFFED4956);
  static const Color success = Color(0xFF2ECC71);

  static const LinearGradient brandGradient = LinearGradient(
    colors: [accentOrange, accentPurple],
  );

  static const LinearGradient progressGradient = LinearGradient(
    colors: [Color(0xFFFF6B9D), Color(0xFFE91E63)],
  );

  static const LinearGradient instagramGradient = LinearGradient(
    colors: [
      Color(0xFFF58529),
      Color(0xFFDD2A7B),
      Color(0xFF8134AF),
    ],
  );
}
