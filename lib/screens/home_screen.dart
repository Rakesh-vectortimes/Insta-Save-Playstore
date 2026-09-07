import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/responsive.dart';
import '../core/url_detector.dart';
import '../models/download_item.dart';
import '../models/post_result.dart';
import '../models/profile_result.dart';
import '../models/reel_result.dart';
import '../services/download_history_service.dart';
import '../services/download_service.dart';
import '../services/instagram_api_service.dart';
import '../services/instagram_session.dart';
import '../widgets/app_logo.dart';
import '../widgets/content_preview_card.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/error_banner.dart';
import '../widgets/quality_selector.dart';
import '../widgets/rolling_disclaimer.dart';
import 'carousel_screen.dart';
import 'how_to_download_screen.dart';
import 'instagram_browser_screen.dart';
import 'privacy_policy_screen.dart';
import 'profile_pic_screen.dart';
import 'terms_of_use_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _downloadService = DownloadService();
  final _previewScrollController = ScrollController();

  bool _isFetching = false;
  bool _isSaving = false;
  bool _isProfileLoading = false;
  bool _isProfileSaving = false;
  String? _errorMessage;
  String? _profileErrorMessage;
  bool _scopeLimited = false;
  bool _retryable = false;
  bool _profileScopeLimited = false;
  bool _profileRetryable = false;
  String? _statusMessage;

  String? _sourceUrl;
  ReelResult? _reel;
  PostResult? _post;
  ProfileResult? _profile;
  String _selectedFormat = 'mp4';
  int _selectedQuality = 720;
  DownloadItem? _lastSavedItem;
  String? _lastHandledClipboard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboardAndAutoPaste();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    _usernameController.dispose();
    _previewScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardAndAutoPaste();
    }
  }

  Future<void> _checkClipboardAndAutoPaste({bool forceFetch = true}) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) return;
      if (text == _lastHandledClipboard) return;

      final extracted = UrlDetector.extractInstagramUrl(text);
      if (extracted == null) return;

      final detection = UrlDetector.detect(extracted);
      if (detection.isError || detection.normalizedUrl == null) return;

      _lastHandledClipboard = text;
      final url = detection.normalizedUrl!;
      if (_urlController.text.trim() == url && _hasPreview) return;

      _urlController.text = url;
      _urlController.selection = TextSelection.collapsed(offset: url.length);

      if (forceFetch && !_isFetching && !_isSaving) {
        await _fetchContent();
      }
    } catch (_) {
      // Clipboard may be unavailable on some devices/OS versions.
    }
  }

  bool get _hasPreview => _reel != null || _post != null;

  Future<void> _fetchContent() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _isFetching = true;
      _errorMessage = null;
      _scopeLimited = false;
      _retryable = false;
      _statusMessage = 'Fetching video…';
      _reel = null;
      _post = null;
      _lastSavedItem = null;
    });

    final detection = UrlDetector.detect(input);
    if (detection.isError) {
      setState(() {
        _isFetching = false;
        _errorMessage = detection.errorMessage;
        _scopeLimited = detection.type == InstagramUrlType.story;
        _statusMessage = null;
      });
      return;
    }

    _sourceUrl = detection.normalizedUrl;
    final api = ref.read(instagramApiServiceProvider);

    try {
      if (detection.type == InstagramUrlType.profile) {
        final username = UrlDetector.sanitizeUsername(
          detection.normalizedUrl!,
        );
        setState(() {
          _isFetching = false;
          _statusMessage = null;
          if (username.isNotEmpty) {
            _usernameController.text = username;
          }
        });
        await _fetchProfilePicture();
        return;
      }

      if (detection.type == InstagramUrlType.story) {
        // Stories: open built-in Instagram browser (no login prompt).
        setState(() {
          _isFetching = false;
          _statusMessage = null;
          _errorMessage = null;
        });
        await _openInstagramBrowser(
          initialUrl: detection.normalizedUrl!,
        );
        return;
      }

      if (detection.type == InstagramUrlType.reel) {
        final reel = await api.fetchReel(detection.normalizedUrl!);
        final qualities = reel.availableQualitiesForFormat('mp4');
        setState(() {
          _reel = reel;
          _selectedFormat = reel.formats.contains('mp4') ? 'mp4' : reel.formats.first;
          _selectedQuality = qualities.contains(720)
              ? 720
              : (qualities.isNotEmpty ? qualities.last : 720);
          _statusMessage = 'Video ready — tap Save to Gallery to finish.';
        });
        _scrollPreviewIntoView();
      } else {
        final post = await api.fetchPost(detection.normalizedUrl!);
        if (post.isCarousel) {
          if (!mounted) return;
          setState(() => _statusMessage = null);
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CarouselScreen(
                post: post,
                postUrl: detection.normalizedUrl!,
              ),
            ),
          );
        } else {
          setState(() {
            _post = post;
            _statusMessage = post.type == PostType.video
                ? 'Video ready — tap Save to Gallery to finish.'
                : 'Photo ready — tap Save to Gallery to finish.';
          });
          _scrollPreviewIntoView();
        }
      }
    } on ApiException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _scopeLimited = e.scopeLimited;
        _retryable = e.retryable;
        _statusMessage = null;
      });
    } catch (_) {
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
        _retryable = true;
        _statusMessage = null;
      });
    } finally {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  Future<void> _openInstagramBrowser({String? initialUrl}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InstagramBrowserScreen(
          initialUrl: initialUrl ?? 'https://www.instagram.com/',
        ),
      ),
    );
  }

  void _scrollPreviewIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_previewScrollController.hasClients) return;
      _previewScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _saveToDevice({bool asAudio = false}) async {
    if (!_hasPreview || _sourceUrl == null) return;

    setState(() => _isSaving = true);
    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);

    if (mounted) {
      setState(() => _statusMessage = 'Saving to gallery…');
      DownloadProgressDialog.show(context, progressNotifier: progressNotifier);
    }

    try {
      DownloadResult result;
      DownloadItem item;

      if (_reel != null) {
        final format = asAudio ? 'mp3' : _selectedFormat;
        final quality = asAudio ? 360 : _selectedQuality;
        final option = _reel!.findDownload(format: format, quality: quality);
        final url = resolveApiUrl(option?.url ?? _reel!.downloadUrl);
        final saveType =
            format == 'mp3' ? MediaSaveType.audio : MediaSaveType.video;

        result = await _downloadService.downloadAndSave(
          url: url,
          fileName: _downloadService.buildFileName(
            prefix: 'instasave_reel',
            ext: format,
          ),
          saveType: saveType,
          onProgress: (p) => progressNotifier.value = p,
        );

        item = DownloadItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          fileName: result.savedPath.split('/').last,
          localPath: result.savedPath,
          thumbnailUrl: _reel!.thumbnail ?? '',
          sourceUrl: _sourceUrl!,
          type: asAudio || format == 'mp3'
              ? DownloadMediaType.music
              : DownloadMediaType.video,
          quality: _downloadService.qualityLabel(quality),
          fileSizeBytes: result.fileSizeBytes,
          downloadedAt: DateTime.now(),
          author: _reel!.title,
          title: _reel!.title,
        );
      } else {
        final post = _post!;
        final ext = post.ext ?? (post.type == PostType.video ? 'mp4' : 'jpg');
        final saveType = post.type == PostType.video
            ? MediaSaveType.video
            : MediaSaveType.image;

        result = await _downloadService.downloadAndSave(
          url: post.url!,
          fileName: _downloadService.buildFileName(
            prefix: 'instasave_post',
            ext: ext,
          ),
          saveType: saveType,
          onProgress: (p) => progressNotifier.value = p,
        );

        item = DownloadItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          fileName: result.savedPath.split('/').last,
          localPath: result.savedPath,
          thumbnailUrl: post.thumbnail ?? post.url ?? '',
          sourceUrl: _sourceUrl!,
          type: post.type == PostType.video
              ? DownloadMediaType.video
              : DownloadMediaType.photo,
          quality: 'HD',
          fileSizeBytes: result.fileSizeBytes,
          downloadedAt: DateTime.now(),
          author: post.author,
          title: post.title,
        );
      }

      await ref.read(downloadHistoryProvider.notifier).add(item);
      if (mounted) {
        Navigator.of(context).pop();
        setState(() {
          _lastSavedItem = item;
          _statusMessage = 'Saved to gallery successfully.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to gallery successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        setState(() {
          _statusMessage = 'Video ready — tap Save to Gallery to finish.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      progressNotifier.dispose();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _fetchProfilePicture() async {
    final username = UrlDetector.sanitizeUsername(_usernameController.text);
    if (username.isEmpty) {
      setState(() {
        _profileErrorMessage =
            'Enter an Instagram username (e.g. cristiano), without spaces.';
        _profileRetryable = false;
      });
      return;
    }
    if (!UrlDetector.isValidUsername(username)) {
      setState(() {
        _profileErrorMessage =
            'Invalid username. Use letters, numbers, periods or underscores only.';
        _profileRetryable = false;
        _profile = null;
      });
      return;
    }

    // Reflect sanitized username in the field so testers see what was sent.
    if (_usernameController.text.trim() != username) {
      _usernameController.text = username;
    }

    setState(() {
      _isProfileLoading = true;
      _profileErrorMessage = null;
      _profileScopeLimited = false;
      _profileRetryable = false;
      _profile = null;
    });

    try {
      final api = ref.read(instagramApiServiceProvider);
      final profile = await api.fetchProfilePicture(username);
      setState(() => _profile = profile);
    } on ApiException catch (e) {
      setState(() {
        _profileErrorMessage = e.message;
        _profileScopeLimited = e.scopeLimited;
        _profileRetryable = e.retryable;
      });
    } catch (_) {
      setState(() {
        _profileErrorMessage =
            'Unable to retrieve the profile picture. Please check the username and try again.';
        _profileRetryable = true;
      });
    } finally {
      if (mounted) setState(() => _isProfileLoading = false);
    }
  }

  Future<void> _saveProfilePicture() async {
    if (_profile == null || _profile!.username.isEmpty) return;

    if (_profile!.lowQuality) {
      // Don't tell an already-logged-in user to "log in" again — that button
      // does nothing for them and just loops back to the same dialog. Only
      // offer the login path when there's genuinely no Instagram session yet.
      final alreadyLoggedIn = await InstagramSession.hasSession();
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.darkSurface,
          title: Text(
            alreadyLoggedIn
                ? 'Only a soft thumbnail available'
                : 'Sharp DP needs login',
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            alreadyLoggedIn
                ? 'You’re logged in, but Instagram isn’t sharing a sharper image for this account. Soft enhance will still look soft.'
                : 'Instagram only shared a tiny thumbnail. Soft enhance will still look soft.\n\n'
                    'For the real sharp DP: Open Instagram → Log in → come back and search this username again.',
            style: GoogleFonts.poppins(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'enhance'),
              child: Text(
                'Enhance anyway',
                style: GoogleFonts.poppins(color: AppColors.textMuted),
              ),
            ),
            if (!alreadyLoggedIn)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'login'),
                child: Text(
                  'Log in for sharp DP',
                  style: GoogleFonts.poppins(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == null) return;
      if (choice == 'login') {
        await _openInstagramBrowser(
          initialUrl: 'https://www.instagram.com/accounts/login/',
        );
        if (!mounted) return;
        // After returning from browser, re-fetch with session and save if sharper.
        final username = _profile!.username;
        _usernameController.text = username;
        await _fetchProfilePicture();
        if (!mounted || _profile == null) return;
        if (!_profile!.lowQuality) {
          await _saveProfilePictureSkippingPrompt();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Still low-res after login. Tap Save → Enhance anyway, or confirm you’re logged in (home feed visible).',
              ),
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }
    }

    await _saveProfilePictureSkippingPrompt();
  }

  Future<void> _saveProfilePictureSkippingPrompt() async {
    if (_profile == null || _profile!.username.isEmpty) return;

    setState(() => _isProfileSaving = true);
    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);
    final progressMessage = _profile!.lowQuality
        ? 'Enhancing thumbnail (won’t look like real HD)...'
        : 'Downloading profile picture...';

    if (mounted) {
      DownloadProgressDialog.show(
        context,
        progressNotifier: progressNotifier,
        message: progressMessage,
      );
    }

    try {
      final api = ref.read(instagramApiServiceProvider);
      final download = await api.downloadProfilePicture(
        _profile!.username,
        upscale: _profile!.upscaleAvailable || _profile!.lowQuality
            ? true
            : null,
        directUrl: _profile!.dpUrl,
        preferDirect: (_profile!.source == 'webview_hd' ||
                _profile!.source == 'session_hd') &&
            !_profile!.lowQuality &&
            !_profile!.upscaleAvailable &&
            (_profile!.dpSize == null || _profile!.dpSize! >= 640),
        onProgress: (p) => progressNotifier.value = p,
      );

      final fileName = _downloadService.buildFileName(
        prefix:
            'instasave_${_profile!.username}_dp${download.wasUpscaled ? '_enhanced' : ''}',
        ext: 'jpg',
      );
      final result = await _downloadService.saveBytes(
        bytes: download.bytes,
        fileName: fileName,
        saveType: MediaSaveType.image,
      );

      final historyItem = DownloadItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        fileName: result.savedPath.split('/').last,
        localPath: result.savedPath,
        thumbnailUrl: _profile!.dpUrl,
        sourceUrl: 'https://www.instagram.com/${_profile!.username}/',
        type: DownloadMediaType.photo,
        quality: download.wasUpscaled
            ? 'Enhanced'
            : (_profile!.lowQuality ? 'Low' : 'HD'),
        fileSizeBytes: result.fileSizeBytes,
        downloadedAt: DateTime.now(),
        author: _profile!.username,
        title: _profile!.fullName.isNotEmpty
            ? _profile!.fullName
            : _profile!.username,
      );
      await ref.read(downloadHistoryProvider.notifier).add(historyItem);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              download.wasUpscaled
                  ? 'Enhanced thumbnail saved (soft). Log in for sharp DP.'
                  : 'Profile picture saved!',
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      progressNotifier.dispose();
      if (mounted) setState(() => _isProfileSaving = false);
    }
  }

  String get _thumbnailUrl {
    if (_reel != null) return _reel!.thumbnail ?? '';
    if (_post != null) return _post!.thumbnail ?? _post!.url ?? '';
    return '';
  }

  String get _author {
    if (_reel != null) return _reel!.title;
    if (_post != null) return _post!.author;
    return '';
  }

  bool get _isVideo {
    if (_reel != null) return _selectedFormat == 'mp4';
    if (_post != null) return _post!.type == PostType.video;
    return false;
  }

  String get _qualityLabel {
    if (_reel != null) return _downloadService.qualityLabel(_selectedQuality);
    return 'HD';
  }

  String get _estimatedSize {
    if (_lastSavedItem != null) return _lastSavedItem!.fileSizeLabel;
    return '--';
  }

  void _openPrivacyPolicy() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
    );
  }

  void _openTermsOfUse() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TermsOfUseScreen()),
    );
  }

  void _openHowToDownload() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HowToDownloadScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: SafeArea(
        child: Column(
          children: [
            AppTopBar(
              onMenuTap: () {
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: AppColors.darkSurface,
                  constraints: BoxConstraints(
                    maxWidth: AppBreakpoints.isTablet(context)
                        ? 560
                        : double.infinity,
                  ),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (ctx) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.open_in_browser,
                              color: AppColors.textPrimary),
                          title: Text('Open Instagram browser',
                              style: GoogleFonts.poppins(color: AppColors.textPrimary)),
                          subtitle: Text(
                            'Browse stories & tap Save',
                            style: GoogleFonts.poppins(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openInstagramBrowser();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.account_circle_outlined,
                              color: AppColors.textPrimary),
                          title: Text('Profile picture',
                              style: GoogleFonts.poppins(color: AppColors.textPrimary)),
                          onTap: () {
                            Navigator.pop(ctx);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ProfilePicScreen(),
                              ),
                            );
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.help_outline,
                              color: AppColors.textPrimary),
                          title: Text('How to download',
                              style: GoogleFonts.poppins(color: AppColors.textPrimary)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openHowToDownload();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.description_outlined,
                              color: AppColors.textPrimary),
                          title: Text('Terms of Use',
                              style: GoogleFonts.poppins(color: AppColors.textPrimary)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openTermsOfUse();
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.privacy_tip_outlined,
                              color: AppColors.textPrimary),
                          title: Text('Privacy Policy',
                              style: GoogleFonts.poppins(color: AppColors.textPrimary)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openPrivacyPolicy();
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            Expanded(
              child: AdaptiveBody(
                child: Column(
                  children: [
            const RollingDisclaimer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openInstagramBrowser(),
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: Text(
                        'Open Instagram',
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.darkBorder),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _openHowToDownload,
                    icon: const Icon(Icons.help_outline, size: 16),
                    label: Text(
                      'How to?',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.darkInput,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _urlController,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Paste Instagram link here',
                          hintStyle: GoogleFonts.poppins(
                            color: AppColors.textMuted,
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onSubmitted: (_) => _fetchContent(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: (_isFetching || _isSaving) ? null : _fetchContent,
                    style: TextButton.styleFrom(
                      backgroundColor: AppColors.darkCard,
                      foregroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isFetching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.accent,
                            ),
                          )
                        : Text(
                            'Get Video',
                            style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                          ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.darkInput,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _usernameController,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Enter username (e.g. cristiano)',
                          hintStyle: GoogleFonts.poppins(
                            color: AppColors.textMuted,
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onSubmitted: (_) => _fetchProfilePicture(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: (_isProfileLoading || _isProfileSaving)
                        ? null
                        : _fetchProfilePicture,
                    style: TextButton.styleFrom(
                      backgroundColor: AppColors.darkCard,
                      foregroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isProfileLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.accent,
                            ),
                          )
                        : Text(
                            'Get DP',
                            style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                          ),
                  ),
                ],
              ),
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ErrorBanner(
                  message: _errorMessage!,
                  scopeLimited: _scopeLimited,
                  retryable: _retryable,
                  onRetry: _fetchContent,
                ),
              ),
            if (_profileErrorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ErrorBanner(
                  message: _profileErrorMessage!,
                  scopeLimited: _profileScopeLimited,
                  retryable: _profileRetryable,
                  onRetry: _fetchProfilePicture,
                ),
              ),
            if (_profile != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.darkSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.darkBorder),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 26,
                          backgroundColor: AppColors.darkCard,
                          backgroundImage: NetworkImage(_profile!.dpUrl),
                          onBackgroundImageError: (_, __) {},
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '@${_profile!.username}',
                                style: GoogleFonts.poppins(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _profile!.fullName.isNotEmpty
                                    ? _profile!.fullName
                                    : 'Profile picture ready',
                                style: GoogleFonts.poppins(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              if (_profile!.source != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  _profile!.source == 'webview_hd'
                                      ? 'HD from profile page'
                                      : _profile!.source == 'webview_standard'
                                          ? 'Standard from profile page'
                                          : 'Source: ${_profile!.source}',
                                  style: GoogleFonts.poppins(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                              if (_profile!.lowQuality) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Low-res thumb — log in for sharp DP',
                                  style: GoogleFonts.poppins(
                                    color: AppColors.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _isProfileSaving ? null : _saveProfilePicture,
                          style: TextButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _isProfileSaving
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  'Save',
                                  style:
                                      GoogleFonts.poppins(fontWeight: FontWeight.w600),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _isFetching
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 120,
                            width: 120,
                            child: CircularProgressIndicator(
                              color: AppColors.accent,
                              strokeWidth: 3,
                              value: null,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Fetching video…',
                            style: GoogleFonts.poppins(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _hasPreview
                      ? Column(
                          children: [
                            if (_statusMessage != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.success.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: AppColors.success.withOpacity(0.35),
                                    ),
                                  ),
                                  child: Text(
                                    _statusMessage!,
                                    style: GoogleFonts.poppins(
                                      color: AppColors.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                              child: SizedBox(
                                width: double.infinity,
                                height: 50,
                                child: ElevatedButton.icon(
                                  onPressed: _isSaving ? null : _saveToDevice,
                                  icon: Icon(
                                    _isSaving
                                        ? Icons.hourglass_top_rounded
                                        : Icons.download_rounded,
                                    color: Colors.white,
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.accent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  label: Text(
                                    _isSaving
                                        ? 'Saving to gallery…'
                                        : 'Save to Gallery',
                                    style: GoogleFonts.poppins(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                controller: _previewScrollController,
                                child: Column(
                                  children: [
                                    if (_reel != null) ...[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        child: FormatSelector(
                                          formats:
                                              _reel!.formats.toSet().toList(),
                                          selectedFormat: _selectedFormat,
                                          onFormatSelected: (f) =>
                                              setState(() {
                                            _selectedFormat = f;
                                            final q = _reel!
                                                .availableQualitiesForFormat(f);
                                            if (!q.contains(_selectedQuality) &&
                                                q.isNotEmpty) {
                                              _selectedQuality =
                                                  q.contains(720) ? 720 : q.last;
                                            }
                                          }),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        child: QualitySelector(
                                          qualities: _reel!
                                              .availableQualitiesForFormat(
                                            _selectedFormat,
                                          ),
                                          selectedQuality: _selectedQuality,
                                          onQualitySelected: (q) => setState(
                                            () => _selectedQuality = q,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    ContentPreviewCard(
                                      thumbnailUrl: _thumbnailUrl,
                                      fileSizeLabel: _estimatedSize,
                                      qualityLabel: _qualityLabel,
                                      author: _author,
                                      isVideo: _isVideo,
                                      onMoreTap: null,
                                    ),
                                    const SizedBox(height: 24),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        )
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.link,
                                size: 48,
                                color: AppColors.textMuted.withOpacity(0.5),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Paste a link and tap Get Video',
                                style: GoogleFonts.poppins(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Then tap Save to Gallery to finish',
                                style: GoogleFonts.poppins(
                                  color: AppColors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
            ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
