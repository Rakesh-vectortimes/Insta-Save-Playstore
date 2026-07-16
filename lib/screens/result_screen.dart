import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../models/post_result.dart';
import '../models/reel_result.dart';
import '../services/download_service.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/error_banner.dart';
import '../widgets/media_preview_card.dart';
import '../widgets/quality_selector.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen._({
    required this.reel,
    required this.post,
    this.postUrl,
  });

  factory ResultScreen.reel({required ReelResult reel}) {
    return ResultScreen._(reel: reel, post: null);
  }

  factory ResultScreen.post({
    required PostResult post,
    required String postUrl,
  }) {
    return ResultScreen._(reel: null, post: post, postUrl: postUrl);
  }

  final ReelResult? reel;
  final PostResult? post;
  final String? postUrl;

  bool get isReel => reel != null;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final _downloadService = DownloadService();
  String _selectedFormat = 'mp4';
  int _selectedQuality = 720;
  bool _isDownloading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.isReel) {
      final reel = widget.reel!;
      _selectedFormat = reel.formats.contains('mp4') ? 'mp4' : reel.formats.first;
      final qualities = reel.availableQualitiesForFormat(_selectedFormat);
      _selectedQuality = qualities.contains(720)
          ? 720
          : (qualities.isNotEmpty ? qualities.last : 720);
    }
  }

  List<int> get _qualities {
    if (!widget.isReel) return [];
    return widget.reel!.availableQualitiesForFormat(_selectedFormat);
  }

  List<String> get _formats {
    if (!widget.isReel) return [];
    return widget.reel!.formats.toSet().toList();
  }

  Future<void> _download() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
    });

    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);

    if (mounted) {
      DownloadProgressDialog.show(
        context,
        progressNotifier: progressNotifier,
      );
    }

    try {
      if (widget.isReel) {
        await _downloadReel(progressNotifier);
      } else {
        await _downloadPost(progressNotifier);
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      progressNotifier.dispose();
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<void> _downloadReel(ValueNotifier<FileDownloadProgress?> progressNotifier) async {
    final reel = widget.reel!;
    final option = reel.findDownload(
      format: _selectedFormat,
      quality: _selectedQuality,
    );

    final downloadUrl = option?.url.isNotEmpty == true
        ? option!.url
        : reel.downloadUrl;

    final saveType = _selectedFormat == 'mp3'
        ? MediaSaveType.audio
        : MediaSaveType.video;

    final fileName = _downloadService.buildFileName(
      prefix: 'instasave_reel',
      ext: _selectedFormat,
    );

    await _downloadService.downloadAndSave(
      url: resolveApiUrl(downloadUrl),
      fileName: fileName,
      saveType: saveType,
      onProgress: (p) => progressNotifier.value = p,
    );
  }

  Future<void> _downloadPost(ValueNotifier<FileDownloadProgress?> progressNotifier) async {
    final post = widget.post!;
    final ext = post.ext ?? (post.type == PostType.video ? 'mp4' : 'jpg');
    final saveType = post.type == PostType.video
        ? MediaSaveType.video
        : MediaSaveType.image;

    final fileName = _downloadService.buildFileName(
      prefix: 'instasave_post',
      ext: ext,
    );

    await _downloadService.downloadAndSave(
      url: post.url!,
      fileName: fileName,
      saveType: saveType,
      onProgress: (p) => progressNotifier.value = p,
    );
  }

  String _formatDuration(double? seconds) {
    if (seconds == null) return '';
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    return '${mins}m ${secs}s';
  }

  @override
  Widget build(BuildContext context) {
    final reel = widget.reel;
    final post = widget.post;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReel ? 'Reel' : 'Post'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MediaPreviewCard(
                imageUrl: widget.isReel ? reel!.thumbnail : post!.thumbnail ?? post.url,
                title: widget.isReel ? reel!.title : post!.title,
                subtitle: widget.isReel
                    ? _formatDuration(reel!.duration)
                    : post!.author.isNotEmpty
                        ? '@${post.author}'
                        : null,
                badge: widget.isReel
                    ? 'Reel'
                    : post!.type == PostType.video
                        ? 'Video'
                        : 'Image',
              ),
              const SizedBox(height: 24),
              if (widget.isReel) ...[
                FormatSelector(
                  formats: _formats,
                  selectedFormat: _selectedFormat,
                  onFormatSelected: (format) {
                    setState(() {
                      _selectedFormat = format;
                      final qualities =
                          widget.reel!.availableQualitiesForFormat(format);
                      if (!qualities.contains(_selectedQuality) &&
                          qualities.isNotEmpty) {
                        _selectedQuality = qualities.contains(720)
                            ? 720
                            : qualities.last;
                      }
                    });
                  },
                ),
                const SizedBox(height: 20),
                QualitySelector(
                  qualities: _qualities,
                  selectedQuality: _selectedQuality,
                  onQualitySelected: (q) => setState(() => _selectedQuality = q),
                ),
                const SizedBox(height: 24),
              ],
              if (_errorMessage != null) ...[
                ErrorBanner(message: _errorMessage!),
                const SizedBox(height: 16),
              ],
              ElevatedButton.icon(
                onPressed: _isDownloading ? null : _download,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
