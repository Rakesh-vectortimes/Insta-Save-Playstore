import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_use_screen.dart';

enum _GuideTab { story, reels, post, music }

class HowToDownloadScreen extends StatefulWidget {
  const HowToDownloadScreen({super.key});

  @override
  State<HowToDownloadScreen> createState() => _HowToDownloadScreenState();
}

class _HowToDownloadScreenState extends State<HowToDownloadScreen> {
  _GuideTab _tab = _GuideTab.reels;

  Future<void> _openInstagram() async {
    final appUri = Uri.parse('instagram://app');
    if (await canLaunchUrl(appUri)) {
      await launchUrl(appUri, mode: LaunchMode.externalApplication);
      return;
    }
    final webUri = Uri.parse('https://www.instagram.com/');
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  void _openTerms() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TermsOfUseScreen()),
    );
  }

  void _openPrivacy() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        title: Text(
          'How to Download',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          _TabBar(
            selected: _tab,
            onSelected: (tab) => setState(() => _tab = tab),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: _buildTabContent(),
            ),
          ),
          _BottomActions(
            onOpenInstagram: _openInstagram,
            onOpenTerms: _openTerms,
            onOpenPrivacy: _openPrivacy,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTabContent() {
    if (_tab == _GuideTab.story) {
      return [
        _NoticeCard(
          text:
              'Stories are not supported in ${AppConstants.appDisplayName}. '
              'Only public posts and reels can be downloaded.',
        ),
        const SizedBox(height: 12),
        ..._copyAndShareMethods(
          subtitle: 'Copy Link to Download',
          step2Copy:
              '2. Go back to \'${AppConstants.appDisplayName}\' to auto-download',
          step2Share:
              '2. Select \'${AppConstants.appDisplayName}\' to auto-download',
        ),
      ];
    }

    if (_tab == _GuideTab.music) {
      return [
        _MethodCard(
          methodNumber: 1,
          title: 'Copy Link to Download Music',
          steps: [
            _GuideStep(
              text:
                  '1. Open Instagram Reels and click the audio button',
              illustration: _IllustrationType.reelAudio,
            ),
            _GuideStep(
              text: '2. Tap ⋮ and click \'Copy link\'',
              illustration: _IllustrationType.copyLink,
            ),
            _GuideStep(
              text:
                  '3. Go back to \'${AppConstants.appDisplayName}\' and save the reel, then use Extract Audio from the Downloads menu',
              illustration: _IllustrationType.appIcon,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _MethodCard(
          methodNumber: 2,
          title: 'Share Link to Download Music',
          steps: [
            _GuideStep(
              text:
                  '1. Open Instagram Reels and click the audio button',
              illustration: _IllustrationType.reelAudio,
            ),
            _GuideStep(
              text: '2. Tap ⋮ and click \'Copy link\'',
              illustration: _IllustrationType.copyLink,
            ),
            _GuideStep(
              text:
                  '3. Select \'${AppConstants.appDisplayName}\' from share options',
              illustration: _IllustrationType.shareSheet,
            ),
          ],
        ),
      ];
    }

    return _copyAndShareMethods(
      subtitle: _tab == _GuideTab.reels
          ? 'Copy Link to Download Reels'
          : 'Copy Link to Download',
      step2Copy:
          '2. Go back to \'${AppConstants.appDisplayName}\' to auto-download',
      step2Share:
          '2. Select \'${AppConstants.appDisplayName}\' to auto-download',
    );
  }

  List<Widget> _copyAndShareMethods({
    required String subtitle,
    required String step2Copy,
    required String step2Share,
  }) {
    return [
      _MethodCard(
        methodNumber: 1,
        title: subtitle,
        steps: [
          _GuideStep(
            text:
                '1. Open Instagram, tap ✈ and click \'Copy link\'',
            illustration: _IllustrationType.copyLink,
          ),
          _GuideStep(
            text: step2Copy,
            illustration: _IllustrationType.appIcon,
          ),
        ],
      ),
      const SizedBox(height: 16),
      _MethodCard(
        methodNumber: 2,
        title: 'Share Link to Download',
        steps: [
          _GuideStep(
            text: '1. Open Instagram, tap ✈ and click \'Share\'',
            illustration: _IllustrationType.shareButton,
          ),
          _GuideStep(
            text: step2Share,
            illustration: _IllustrationType.shareSheet,
          ),
        ],
      ),
    ];
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.selected, required this.onSelected});

  final _GuideTab selected;
  final ValueChanged<_GuideTab> onSelected;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (_GuideTab.story, 'Story'),
      (_GuideTab.reels, 'Reels'),
      (_GuideTab.post, 'Post'),
      (_GuideTab.music, 'Music'),
    ];

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 20),
        itemBuilder: (context, index) {
          final (tab, label) = tabs[index];
          final isSelected = selected == tab;
          return GestureDetector(
            onTap: () => onSelected(tab),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    color: isSelected
                        ? AppColors.textPrimary
                        : AppColors.textMuted,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 3,
                  width: 36,
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.darkBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.methodNumber,
    required this.title,
    required this.steps,
  });

  final int methodNumber;
  final String title;
  final List<_GuideStep> steps;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.darkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Method $methodNumber',
              style: GoogleFonts.poppins(
                color: AppColors.accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          ...steps,
        ],
      ),
    );
  }
}

enum _IllustrationType {
  copyLink,
  shareButton,
  shareSheet,
  appIcon,
  reelAudio,
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({required this.text, required this.illustration});

  final String text;
  final _IllustrationType illustration;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 10),
          _StepIllustration(type: illustration),
        ],
      ),
    );
  }
}

class _StepIllustration extends StatelessWidget {
  const _StepIllustration({required this.type});

  final _IllustrationType type;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 150,
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.darkBorder),
      ),
      child: switch (type) {
        _IllustrationType.copyLink => _buildCopyLink(),
        _IllustrationType.shareButton => _buildShareButton(),
        _IllustrationType.shareSheet => _buildShareSheet(),
        _IllustrationType.appIcon => _buildAppIcon(),
        _IllustrationType.reelAudio => _buildReelAudio(),
      },
    );
  }

  Widget _buildCopyLink() {
    return Stack(
      alignment: Alignment.center,
      children: [
        const Icon(Icons.send_outlined, color: AppColors.textMuted, size: 28),
        Positioned(
          right: 42,
          bottom: 36,
          child: _highlightedChip(Icons.link, 'Copy link'),
        ),
        const Positioned(
          right: 24,
          bottom: 18,
          child: Icon(Icons.touch_app, color: AppColors.accent, size: 28),
        ),
      ],
    );
  }

  Widget _buildShareButton() {
    return Stack(
      alignment: Alignment.center,
      children: [
        const Icon(Icons.send_outlined, color: AppColors.textMuted, size: 28),
        Positioned(
          right: 42,
          bottom: 36,
          child: _highlightedChip(Icons.ios_share, 'Share'),
        ),
        const Positioned(
          right: 24,
          bottom: 18,
          child: Icon(Icons.touch_app, color: AppColors.accent, size: 28),
        ),
      ],
    );
  }

  Widget _buildShareSheet() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _miniApp(Icons.message_outlined, 'Messages'),
          _miniApp(Icons.mail_outline, 'Gmail'),
          _miniApp(Icons.chrome_reader_mode_outlined, 'Chrome'),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: AppColors.brandGradient,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
                child: const Icon(Icons.download_rounded, color: Colors.white),
              ),
              const SizedBox(height: 4),
              Text(
                AppConstants.appDisplayName,
                style: GoogleFonts.poppins(
                  color: AppColors.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppIcon() {
    return Center(
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          gradient: AppColors.brandGradient,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.accent, width: 2),
        ),
        child: const Icon(Icons.download_rounded, color: Colors.white, size: 34),
      ),
    );
  }

  Widget _buildReelAudio() {
    return Stack(
      children: [
        const Center(
          child: Icon(Icons.play_circle_outline,
              color: AppColors.textMuted, size: 48),
        ),
        Positioned(
          right: 24,
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.darkBackground,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accent, width: 2),
            ),
            child: const Icon(Icons.music_note, color: AppColors.accent, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _highlightedChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.darkBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.textPrimary, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniApp(IconData icon, String label) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: AppColors.textMuted, size: 28),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.poppins(color: AppColors.textMuted, fontSize: 9),
        ),
      ],
    );
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({
    required this.onOpenInstagram,
    required this.onOpenTerms,
    required this.onOpenPrivacy,
  });

  final VoidCallback onOpenInstagram;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenPrivacy;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: onOpenInstagram,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                child: Text(
                  'Open Instagram',
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: GoogleFonts.poppins(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
                children: [
                  const TextSpan(text: 'You have read '),
                  TextSpan(
                    text: 'Terms of Use',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()..onTap = onOpenTerms,
                  ),
                  const TextSpan(text: ' & '),
                  TextSpan(
                    text: 'Privacy Policy',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()..onTap = onOpenPrivacy,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
