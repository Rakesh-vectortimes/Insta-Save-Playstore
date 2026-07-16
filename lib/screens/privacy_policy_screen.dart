import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        title: Text(
          'Privacy Policy of ${AppConstants.appDisplayName}',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text(
              'Privacy Policy of ${AppConstants.appDisplayName}',
              style: GoogleFonts.poppins(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Privacy Policy of ${AppConstants.appDisplayName}',
              style: GoogleFonts.poppins(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Last update: December 5, 2024',
              style: GoogleFonts.poppins(
                color: AppColors.success,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),
            _section(
              title: 'Overview',
              body:
                  '${AppConstants.appDisplayName} helps you download publicly available Instagram reels, posts, and profile pictures. We do not require you to log in with an Instagram account.',
            ),
            _section(
              title: 'Public content only',
              body:
                  'This app only supports media from public accounts. Private account content, stories, and content that requires authentication are not supported and cannot be downloaded through the app.',
            ),
            _section(
              title: 'Information we collect',
              body:
                  'We do not collect personal login credentials. Download history and app preferences may be stored locally on your device. Media links you paste are sent to our servers only to process your download request.',
            ),
            _section(
              title: 'How we use information',
              body:
                  'Link and username data is used solely to fetch publicly available media you request. We do not sell your personal data. Server logs may be retained temporarily for security, debugging, and abuse prevention.',
            ),
            _section(
              title: 'Copyright & acceptable use',
              body:
                  'You are responsible for how you use downloaded content. Only download media you have the right to access and use. Respect creators, trademarks, and copyright laws. Do not redistribute, re-upload, or commercially exploit content without permission from the rights holder.',
            ),
            _section(
              title: 'Third-party services',
              body:
                  'Instagram content is provided by third-party platforms. ${AppConstants.appDisplayName} is not affiliated with, endorsed by, or sponsored by Instagram or Meta. Use of downloaded content must comply with Instagram\'s terms and applicable laws.',
            ),
            _section(
              title: 'Children\'s privacy',
              body:
                  'This app is not directed at children under 13. We do not knowingly collect personal information from children.',
            ),
            _section(
              title: 'Data deletion',
              body:
                  'You can remove downloaded files from the Downloads section in the app. Clearing app data on your device will remove locally stored download history.',
            ),
            _section(
              title: 'Changes to this policy',
              body:
                  'We may update this Privacy Policy from time to time. Continued use of the app after changes means you accept the updated policy.',
            ),
            _section(
              title: 'Contact',
              body:
                  'If you have questions about this Privacy Policy, contact us at support@dlreels.com.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({required String title, required String body}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: GoogleFonts.poppins(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}
