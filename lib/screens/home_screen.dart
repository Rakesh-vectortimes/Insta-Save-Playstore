import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/url_detector.dart';
import '../models/download_item.dart';
import '../models/post_result.dart';
import '../models/profile_result.dart';
import '../models/reel_result.dart';
import '../services/download_history_service.dart';
import '../services/download_service.dart';
import '../services/instagram_api_service.dart';
import '../widgets/app_logo.dart';
import '../widgets/content_preview_card.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/error_banner.dart';
import '../widgets/quality_selector.dart';
import '../widgets/rolling_disclaimer.dart';
import 'carousel_screen.dart';
import 'how_to_download_screen.dart';
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
      });
      return;
    }

    _sourceUrl = detection.normalizedUrl;
    final api = ref.read(instagramApiServiceProvider);

    try {
      if (detection.type == InstagramUrlType.reel) {
        final reel = await api.fetchReel(detection.normalizedUrl!);
        final qualities = reel.availableQualitiesForFormat('mp4');
        setState(() {
          _reel = reel;
          _selectedFormat = reel.formats.contains('mp4') ? 'mp4' : reel.formats.first;
          _selectedQuality = qualities.contains(720)
              ? 720
              : (qualities.isNotEmpty ? qualities.last : 720);
        });
      } else {
        final post = await api.fetchPost(detection.normalizedUrl!);
        if (post.isCarousel) {
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CarouselScreen(
                post: post,
                postUrl: detection.normalizedUrl!,
              ),
            ),
          );
        } else {
          setState(() => _post = post);
        }
      }
    } on ApiException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _scopeLimited = e.scopeLimited;
        _retryable = e.retryable;
      });
    } catch (_) {
      setState(() {
        _errorMessage = 'Something went wrong. Please try again.';
        _retryable = true;
      });
    } finally {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  Future<void> _saveToDevice({bool asAudio = false}) async {
    if (!_hasPreview || _sourceUrl == null) return;

    setState(() => _isSaving = true);
    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);

    if (mounted) {
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
        setState(() => _lastSavedItem = item);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved successfully!')),
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
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _fetchProfilePicture() async {
    final username = UrlDetector.sanitizeUsername(_usernameController.text);
    if (username.isEmpty) return;

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
        _profileErrorMessage = 'Something went wrong. Please try again.';
        _profileRetryable = true;
      });
    } finally {
      if (mounted) setState(() => _isProfileLoading = false);
    }
  }

  Future<void> _saveProfilePicture() async {
    if (_profile == null || _profile!.dpUrl.isEmpty) return;

    setState(() => _isProfileSaving = true);
    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);

    if (mounted) {
      DownloadProgressDialog.show(context, progressNotifier: progressNotifier);
    }

    try {
      final fileName = _downloadService.buildFileName(
        prefix: 'instasave_${_profile!.username}',
        ext: 'jpg',
      );
      final result = await _downloadService.downloadAndSave(
        url: _profile!.dpUrl,
        fileName: fileName,
        saveType: MediaSaveType.image,
        onProgress: (p) => progressNotifier.value = p,
      );

      final historyItem = DownloadItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        fileName: result.savedPath.split('/').last,
        localPath: result.savedPath,
        thumbnailUrl: _profile!.dpUrl,
        sourceUrl: 'https://www.instagram.com/${_profile!.username}/',
        type: DownloadMediaType.photo,
        quality: 'HD',
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
          const SnackBar(content: Text('Profile picture saved!')),
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
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (ctx) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
            const RollingDisclaimer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _openHowToDownload,
                  icon: const Icon(Icons.help_outline, size: 16),
                  label: Text(
                    'How to download?',
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
                            'Download',
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
                          hintText: 'Enter username (e.g. leo messi)',
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
                            'Fetching content...',
                            style: GoogleFonts.poppins(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _hasPreview
                      ? SingleChildScrollView(
                          child: Column(
                            children: [
                              ContentPreviewCard(
                                thumbnailUrl: _thumbnailUrl,
                                fileSizeLabel: _estimatedSize,
                                qualityLabel: _qualityLabel,
                                author: _author,
                                isVideo: _isVideo,
                                onMoreTap: null,
                              ),
                              if (_reel != null) ...[
                                const SizedBox(height: 16),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: FormatSelector(
                                    formats: _reel!.formats.toSet().toList(),
                                    selectedFormat: _selectedFormat,
                                    onFormatSelected: (f) => setState(() {
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
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: QualitySelector(
                                    qualities: _reel!
                                        .availableQualitiesForFormat(_selectedFormat),
                                    selectedQuality: _selectedQuality,
                                    onQualitySelected: (q) =>
                                        setState(() => _selectedQuality = q),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: SizedBox(
                                  width: double.infinity,
                                  height: 50,
                                  child: ElevatedButton(
                                    onPressed: _isSaving ? null : _saveToDevice,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.accent,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: Text(
                                      _isSaving ? 'Saving...' : 'Save to Gallery',
                                      style: GoogleFonts.poppins(
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],
                          ),
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
                                'Paste a link and tap Download',
                                style: GoogleFonts.poppins(
                                  color: AppColors.textSecondary,
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
