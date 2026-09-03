import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../core/constants.dart';
import '../models/download_item.dart';

class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({
    super.key,
    required this.item,
  });

  final DownloadItem item;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  VideoPlayerController? _videoController;
  bool _isInitializing = false;
  bool _showControls = true;
  String? _error;

  bool get _isVideo => widget.item.type == DownloadMediaType.video;

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    setState(() => _isInitializing = true);
    try {
      final controller = VideoPlayerController.file(File(widget.item.localPath));
      await controller.initialize();
      await controller.setLooping(true);
      controller.addListener(_onVideoTick);
      setState(() => _videoController = controller);
      await controller.play();
    } catch (_) {
      setState(() => _error = 'Unable to play this video file.');
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  Future<void> _share() async {
    final file = File(widget.item.localPath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File not found')),
      );
      return;
    }
    await Share.shareXFiles([XFile(widget.item.localPath)]);
  }

  void _togglePlayPause() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  Future<void> _seekBy(Duration offset) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final current = controller.value.position;
    final total = controller.value.duration;
    var target = current + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    await controller.seekTo(target);
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    final hours = d.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _videoController?.removeListener(_onVideoTick);
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          widget.item.title?.isNotEmpty == true
              ? widget.item.title!
              : widget.item.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: _share,
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
          ),
        ],
      ),
      body: SafeArea(
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: AppColors.textPrimary),
        ),
      );
    }

    if (_isVideo) {
      if (_isInitializing ||
          _videoController == null ||
          !_videoController!.value.isInitialized) {
        return const Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        );
      }
      return _buildVideoPlayer(_videoController!);
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    final imageWidth = screenWidth > 900 ? 900.0 : screenWidth;
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: Image.file(
          File(widget.item.localPath),
          width: imageWidth,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.broken_image_outlined,
            color: AppColors.textSecondary,
            size: 56,
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPlayer(VideoPlayerController controller) {
    final position = controller.value.position;
    final duration = controller.value.duration;
    final maxMs = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final valueMs = position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();

    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio == 0
                  ? 16 / 9
                  : controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          if (_showControls) ...[
            Container(color: Colors.black26),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () => _seekBy(const Duration(seconds: -5)),
                    iconSize: 40,
                    color: Colors.white,
                    icon: const Icon(Icons.replay_5),
                    tooltip: 'Back 5 seconds',
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    onPressed: _togglePlayPause,
                    iconSize: 64,
                    color: Colors.white,
                    icon: Icon(
                      controller.value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    onPressed: () => _seekBy(const Duration(seconds: 5)),
                    iconSize: 40,
                    color: Colors.white,
                    icon: const Icon(Icons.forward_5),
                    tooltip: 'Forward 5 seconds',
                  ),
                ],
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: AppColors.accent,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: AppColors.accent,
                      overlayColor: AppColors.accent.withOpacity(0.2),
                    ),
                    child: Slider(
                      min: 0,
                      max: maxMs,
                      value: valueMs,
                      onChanged: (v) {
                        controller.seekTo(Duration(milliseconds: v.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
