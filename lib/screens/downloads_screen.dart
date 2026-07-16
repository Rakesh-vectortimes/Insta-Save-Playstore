import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../models/download_item.dart';
import '../services/download_history_service.dart';
import '../widgets/app_logo.dart';
import '../widgets/media_options_sheet.dart';
import 'media_viewer_screen.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  DownloadMediaType? _filter;
  DownloadSortOption _sort = DownloadSortOption.downloadTime;

  static const _filters = [
    (null, 'All'),
    (DownloadMediaType.video, 'Video'),
    (DownloadMediaType.photo, 'Photo'),
    (DownloadMediaType.music, 'Music'),
  ];

  Future<void> _showSort() async {
    final result = await showSortDialog(context);
    if (result != null) setState(() => _sort = result);
  }

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(downloadHistoryProvider);
    var items = List<DownloadItem>.from(allItems);
    if (_filter != null) {
      items = items.where((i) => i.type == _filter).toList();
    }
    switch (_sort) {
      case DownloadSortOption.downloadTime:
        items.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      case DownloadSortOption.fileSize:
        items.sort((a, b) => b.fileSizeBytes.compareTo(a.fileSizeBytes));
    }

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTopBar(
              onMenuTap: _showSort,
              trailing: [
                IconButton(
                  onPressed: _showSort,
                  icon: const Icon(Icons.sort, color: AppColors.textPrimary, size: 22),
                  tooltip: 'Sort',
                ),
              ],
            ),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _filters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final (type, label) = _filters[index];
                  final selected = _filter == type;
                  return GestureDetector(
                    onTap: () => setState(() => _filter = type),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.darkCard : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected
                              ? AppColors.darkBorder
                              : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        label,
                        style: GoogleFonts.poppins(
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.download_outlined,
                            size: 56,
                            color: AppColors.textMuted.withOpacity(0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            allItems.isEmpty
                                ? 'No downloads yet'
                                : 'No items in this category',
                            style: GoogleFonts.poppins(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.62,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return _DownloadGridItem(
                          item: item,
                          onOpen: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => MediaViewerScreen(item: item),
                            ),
                          ),
                          onShare: () => Share.shareXFiles(
                            [XFile(item.localPath)],
                          ),
                          onMore: () => showMediaOptionsSheet(
                            context: context,
                            ref: ref,
                            item: item,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadGridItem extends StatelessWidget {
  const _DownloadGridItem({
    required this.item,
    required this.onOpen,
    required this.onShare,
    required this.onMore,
  });

  final DownloadItem item;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final author = item.author?.trim() ?? '';
    final subtitle = author.isNotEmpty ? '@$author' : item.fileName;
    final avatarText = author.isNotEmpty ? author[0].toUpperCase() : '?';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.type == DownloadMediaType.music ? null : onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.darkCard,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildPreview(),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          item.type == DownloadMediaType.video
                              ? Icons.videocam
                              : item.type == DownloadMediaType.music
                                  ? Icons.music_note
                                  : Icons.image,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          item.quality,
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    if (item.type == DownloadMediaType.video)
                      const Center(
                        child: Icon(Icons.play_circle_fill,
                            color: Colors.white70, size: 36),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 10,
                      backgroundColor: AppColors.primary,
                      child: Text(
                        avatarText,
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        subtitle,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: onShare,
                      icon: const Icon(Icons.share, size: 16),
                      color: AppColors.textPrimary,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                    IconButton(
                      onPressed: onMore,
                      icon: const Icon(Icons.more_vert, size: 16),
                      color: AppColors.textPrimary,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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

  Widget _buildPreview() {
    if (item.type == DownloadMediaType.photo) {
      return Image.file(
        File(item.localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildNetworkFallback(),
      );
    }

    return _buildNetworkFallback();
  }

  Widget _buildNetworkFallback() {
    if (item.thumbnailUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: item.thumbnailUrl,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: AppColors.darkSurface,
      child: const Icon(Icons.perm_media, color: AppColors.textMuted),
    );
  }
}
