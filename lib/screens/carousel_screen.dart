import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/responsive.dart';
import '../models/carousel_item.dart';
import '../models/download_item.dart';
import '../models/post_result.dart';
import '../services/download_history_service.dart';
import '../services/download_service.dart';
import '../services/instagram_api_service.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/error_banner.dart';

class CarouselScreen extends ConsumerStatefulWidget {
  const CarouselScreen({
    super.key,
    required this.post,
    required this.postUrl,
  });

  final PostResult post;
  final String postUrl;

  @override
  ConsumerState<CarouselScreen> createState() => _CarouselScreenState();
}

class _CarouselScreenState extends ConsumerState<CarouselScreen> {
  final _downloadService = DownloadService();
  String? _errorMessage;
  bool _scopeLimited = false;
  bool _retryable = false;
  bool _isBusy = false;

  Future<DownloadResult> _saveItem(
    CarouselItem item, {
    void Function(FileDownloadProgress progress)? onProgress,
  }) async {
    final saveType = item.isVideo ? MediaSaveType.video : MediaSaveType.image;
    final fileName = _downloadService.buildFileName(
      prefix: 'instasave_carousel',
      ext: item.ext,
      index: item.index,
    );

    final result = await _downloadService.downloadAndSave(
      url: item.url,
      fileName: fileName,
      saveType: saveType,
      onProgress: onProgress,
    );

    final historyItem = DownloadItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: result.savedPath.split('/').last,
      localPath: result.savedPath,
      thumbnailUrl: item.thumbnail ?? item.url,
      sourceUrl: widget.postUrl,
      type: item.isVideo ? DownloadMediaType.video : DownloadMediaType.photo,
      quality: 'HD',
      fileSizeBytes: result.fileSizeBytes,
      downloadedAt: DateTime.now(),
      author: widget.post.author,
      title: widget.post.title,
    );
    await ref.read(downloadHistoryProvider.notifier).add(historyItem);
    return result;
  }

  Future<void> _downloadItem(int index) async {
    if (_isBusy) return;
    final item = widget.post.items.firstWhere((i) => i.index == index);
    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);

    setState(() => _isBusy = true);
    if (mounted) {
      DownloadProgressDialog.show(context, progressNotifier: progressNotifier);
    }

    try {
      await _saveItem(item, onProgress: (p) => progressNotifier.value = p);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Item ${item.index} saved to gallery!')),
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
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _downloadAllItems() async {
    final items = widget.post.items;
    if (_isBusy || items.isEmpty) return;

    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);
    final messageNotifier = ValueNotifier<String>('Downloading 1 of ${items.length}...');

    setState(() => _isBusy = true);
    if (mounted) {
      DownloadProgressDialog.show(
        context,
        progressNotifier: progressNotifier,
        messageNotifier: messageNotifier,
      );
    }

    var saved = 0;
    try {
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        messageNotifier.value = 'Downloading ${i + 1} of ${items.length}...';
        progressNotifier.value = null;
        await _saveItem(item, onProgress: (p) => progressNotifier.value = p);
        saved++;
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved $saved items to gallery!')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        final prefix = saved > 0 ? 'Saved $saved, then failed: ' : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$prefix${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    } finally {
      progressNotifier.dispose();
      messageNotifier.dispose();
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _downloadAllZip() async {
    if (_isBusy) return;

    setState(() {
      _errorMessage = null;
      _scopeLimited = false;
      _retryable = false;
      _isBusy = true;
    });

    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);

    if (mounted) {
      DownloadProgressDialog.show(
        context,
        progressNotifier: progressNotifier,
        message: 'Preparing ZIP...',
      );
    }

    try {
      final api = ref.read(instagramApiServiceProvider);
      final bytes = await api.downloadCarouselZip(widget.postUrl);

      final fileName = _downloadService.buildFileName(
        prefix: 'instasave_carousel',
        ext: 'zip',
      );

      await _downloadService.saveBytes(
        bytes: bytes,
        fileName: fileName,
        saveType: MediaSaveType.zip,
      );

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ZIP saved to Downloads folder!')),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        setState(() {
          _errorMessage = e.message;
          _scopeLimited = e.scopeLimited;
          _retryable = e.retryable;
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _retryable = true;
        });
      }
    } finally {
      progressNotifier.dispose();
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.post.items;
    final count = widget.post.count ?? items.length;

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: const Text('Carousel'),
      ),
      body: SafeArea(
        child: AdaptiveBody(
          child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.post.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (widget.post.author.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '@${widget.post.author}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '$count items',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    ErrorBanner(
                      message: _errorMessage!,
                      scopeLimited: _scopeLimited,
                      retryable: _retryable,
                      onRetry: _downloadAllZip,
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No preview items available.\nYou can still download everything as a ZIP.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: AppBreakpoints.pagePadding(context),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: AppBreakpoints.gridCount(context),
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return _CarouselItemCard(
                          item: item,
                          onDownload: _isBusy
                              ? null
                              : () => _downloadItem(item.index),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (items.isNotEmpty)
                    ElevatedButton.icon(
                      onPressed: _isBusy ? null : _downloadAllItems,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Download all as photos'),
                    ),
                  if (items.isNotEmpty) const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _isBusy ? null : _downloadAllZip,
                    icon: const Icon(Icons.folder_zip_outlined),
                    label: const Text('Download all as ZIP'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.primary),
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _CarouselItemCard extends StatelessWidget {
  const _CarouselItemCard({
    required this.item,
    required this.onDownload,
  });

  final CarouselItem item;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final thumbnail = resolveApiUrl(item.thumbnail ?? item.url);

    return Card(
      color: AppColors.darkCard,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumbnail.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: thumbnail,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      color: AppColors.darkSurface,
                      child: const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: AppColors.darkSurface,
                      child: const Icon(
                        Icons.broken_image,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  Container(
                    color: AppColors.darkSurface,
                    child: const Icon(
                      Icons.image_outlined,
                      color: AppColors.textSecondary,
                    ),
                  ),
                if (item.isVideo)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      size: 40,
                      color: Colors.white70,
                    ),
                  ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '#${item.index}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onDownload,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 13),
                ),
                child: const Text('Download'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
