import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/responsive.dart';
import '../core/url_detector.dart';
import '../models/download_item.dart';
import '../models/profile_result.dart';
import '../services/download_history_service.dart';
import '../services/download_service.dart';
import '../services/instagram_api_service.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/error_banner.dart';
import '../widgets/loading_indicator.dart';

class ProfilePicScreen extends ConsumerStatefulWidget {
  const ProfilePicScreen({super.key});

  @override
  ConsumerState<ProfilePicScreen> createState() => _ProfilePicScreenState();
}

class _ProfilePicScreenState extends ConsumerState<ProfilePicScreen> {
  final _usernameController = TextEditingController();
  final _downloadService = DownloadService();

  bool _isLoading = false;
  bool _isDownloading = false;
  ProfileResult? _profile;
  String? _errorMessage;
  bool _scopeLimited = false;
  bool _retryable = false;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final username = UrlDetector.sanitizeUsername(_usernameController.text);
    if (username.isEmpty) {
      setState(() {
        _errorMessage =
            'Enter an Instagram username (e.g. cristiano), without spaces.';
        _retryable = false;
      });
      return;
    }
    if (!UrlDetector.isValidUsername(username)) {
      setState(() {
        _errorMessage =
            'Invalid username. Use letters, numbers, periods or underscores only.';
        _retryable = false;
        _profile = null;
      });
      return;
    }

    if (_usernameController.text.trim() != username) {
      _usernameController.text = username;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _scopeLimited = false;
      _retryable = false;
      _profile = null;
    });

    try {
      final api = ref.read(instagramApiServiceProvider);
      final result = await api.fetchProfilePicture(username);
      setState(() => _profile = result);
    } on ApiException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _scopeLimited = e.scopeLimited;
        _retryable = e.retryable;
      });
    } catch (_) {
      setState(() {
        _errorMessage =
            'Unable to retrieve the profile picture. Please check the username and try again.';
        _retryable = true;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _download() async {
    final profile = _profile;
    if (profile == null || profile.username.isEmpty) return;

    setState(() => _isDownloading = true);
    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);
    final progressMessage = profile.upscaleAvailable
        ? 'Fetching HD profile picture...'
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
        profile.username,
        upscale: profile.upscaleAvailable ? true : null,
        directUrl: profile.dpUrl,
        preferDirect: profile.source?.startsWith('webview') == true &&
            !profile.upscaleAvailable,
        onProgress: (p) => progressNotifier.value = p,
      );

      final fileName = _downloadService.buildFileName(
        prefix: 'instasave_${profile.username}_dp${download.wasUpscaled ? '_hd' : ''}',
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
        thumbnailUrl: profile.dpUrl,
        sourceUrl: 'https://www.instagram.com/${profile.username}/',
        type: DownloadMediaType.photo,
        quality: download.wasUpscaled ? 'Upscaled' : 'HD',
        fileSizeBytes: result.fileSizeBytes,
        downloadedAt: DateTime.now(),
        author: profile.username,
        title: profile.fullName.isNotEmpty ? profile.fullName : profile.username,
      );
      await ref.read(downloadHistoryProvider.notifier).add(historyItem);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              download.wasUpscaled
                  ? 'HD profile picture saved!'
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
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  String _formatFollowers(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M followers';
    }
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K followers';
    }
    return '$count followers';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: const Text('Profile Picture'),
      ),
      body: SafeArea(
        child: AdaptiveBody(
          maxWidth: 640,
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter an Instagram username to download their profile picture.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _usernameController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _isLoading ? null : _search(),
                decoration: const InputDecoration(
                  hintText: 'Enter username (e.g. cristiano)',
                  prefixIcon: Icon(Icons.alternate_email, color: AppColors.primary),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isLoading ? null : _search,
                child: _isLoading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Search'),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                ErrorBanner(
                  message: _errorMessage!,
                  scopeLimited: _scopeLimited,
                  retryable: _retryable,
                  onRetry: _search,
                ),
              ],
              if (_isLoading) ...[
                const SizedBox(height: 40),
                const LoadingIndicator(message: 'Fetching profile...'),
              ],
              if (_profile != null) ...[
                const SizedBox(height: 32),
                _ProfileCard(
                  profile: _profile!,
                  formatFollowers: _formatFollowers,
                ),
                const SizedBox(height: 24),
                if (_profile!.isPrivate)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.lock_outline, color: Colors.orange),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'This is a private account. Profile picture may be low resolution. Post and reel downloads are not available.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_profile!.upscaleNote != null && _profile!.lowQuality)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.darkSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.darkBorder),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.hd_outlined,
                          color: AppColors.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _profile!.upscaleNote!,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: _isDownloading ? null : _download,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    _profile!.upscaleAvailable
                        ? 'Download HD profile picture'
                        : 'Download profile picture',
                  ),
                ),
              ],
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.formatFollowers,
  });

  final ProfileResult profile;
  final String Function(int) formatFollowers;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            CircleAvatar(
              radius: 56,
              backgroundColor: Colors.grey.shade200,
              child: ClipOval(
                child: CachedNetworkImage(
                  imageUrl: resolveApiUrl(profile.dpUrl),
                  width: 112,
                  height: 112,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                  errorWidget: (_, __, ___) =>
                      const Icon(Icons.person, size: 48),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              profile.fullName.isNotEmpty ? profile.fullName : profile.username,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              '@${profile.username}',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (profile.followers > 0) ...[
              const SizedBox(height: 8),
              Text(
                formatFollowers(profile.followers),
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
