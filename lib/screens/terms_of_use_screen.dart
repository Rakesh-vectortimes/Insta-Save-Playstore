import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';

class TermsOfUseScreen extends StatelessWidget {
  const TermsOfUseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        title: Text(
          'Terms of Use of ${AppConstants.appDisplayName}',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text(
              'Terms of Use of ${AppConstants.appDisplayName}',
              style: GoogleFonts.poppins(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Terms of Use of ${AppConstants.appDisplayName}',
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
            const SizedBox(height: 24),
            _section(
              title: 'Introduction',
              body:
                  'This Application is provided by ${AppConstants.appDisplayName} (hereinafter referred to as "We").\n\n'
                  '"This Application" refers to applications for mobile, tablet and other smart device systems, and the Service.\n\n'
                  'We provide services for downloading publicly available videos, photos, and profile pictures from Instagram on demand (hereinafter referred to as "Services").\n\n'
                  'Individuals or enterprises (hereinafter referred to as "You" or "Users") shall thoroughly and carefully read these Terms of Use (hereinafter referred to as "Agreement") before using or accessing our Services. By using our Services, You are deemed to have fully understood and accepted all terms and conditions. If You disagree with this Agreement in whole or part, You may stop using our Services at any time.',
            ),
            _section(
              title: 'What You should know at a glance',
              body:
                  'Certain provisions may apply only to specific categories of Users. Where limitations apply, they are mentioned within the relevant clause.\n\n'
                  'Usage of this Application and the Service is age restricted. Users must be older than 13.\n\n'
                  'The Service is intended for personal, non-commercial use only.',
            ),
            _section(
              title: 'Condition of Use',
              body:
                  'Unless otherwise specified, the terms in this section apply generally when using this Application.\n\n'
                  'By using this Application, You confirm that:\n'
                  '• You use the app only for lawful personal purposes;\n'
                  '• You only download publicly available content;\n'
                  '• You are older than 13;\n'
                  '• You will respect copyright and creator rights.',
            ),
            _section(
              title: 'Supported content',
              body:
                  '${AppConstants.appDisplayName} supports public Instagram reels, posts, carousels, and profile pictures. '
                  'Stories, private account content, and content requiring login are not supported.',
            ),
            _section(
              title: 'Content on this Application',
              body:
                  'Unless otherwise specified, all content available through this Application is provided for the purpose of enabling downloads of third-party media You choose to access.\n\n'
                  'We are not responsible for the content hosted on Instagram or other third-party platforms. If You believe content infringes your rights, contact us at support@dlreels.com.',
            ),
            _section(
              title: 'Rights regarding content',
              body:
                  'You may download and save content only for personal, non-commercial use, and only when You have the legal right to do so.\n\n'
                  'You may not copy, redistribute, re-upload, sublicense, sell, or commercially exploit downloaded content without permission from the rights holder.',
            ),
            _section(
              title: 'Access to external resources',
              body:
                  'Through this Application, Users may access external resources provided by third parties such as Instagram. We have no control over such resources and are not responsible for their content or availability.',
            ),
            _section(
              title: 'Disclaimer',
              body:
                  '${AppConstants.appDisplayName} is not affiliated with, endorsed by, or sponsored by Instagram or Meta. Instagram is a trademark of its respective owner.',
            ),
            _section(
              title: 'Contact',
              body: 'For questions about these Terms, contact support@dlreels.com.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({required String title, required String body}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              color: AppColors.accent,
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
