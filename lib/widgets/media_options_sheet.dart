import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../models/download_item.dart';
import '../services/download_history_service.dart';

enum MediaOption {
  extractAudio,
  openInstagram,
  share,
  copyLink,
  viewLocation,
  delete,
}

Future<void> showMediaOptionsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required DownloadItem item,
  VoidCallback? onExtractAudio,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.darkSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.darkBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            _OptionTile(
              icon: Icons.music_note_rounded,
              label: 'Extract Audio from Video',
              onTap: () {
                Navigator.pop(ctx);
                onExtractAudio?.call();
              },
              visible: item.type == DownloadMediaType.video,
            ),
            _OptionTile(
              icon: Icons.camera_alt_outlined,
              label: 'Open on Instagram',
              onTap: () async {
                Navigator.pop(ctx);
                final opened = await _openOnInstagram(item.sourceUrl);
                if (!opened && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Could not open Instagram link'),
                    ),
                  );
                }
              },
            ),
            _OptionTile(
              icon: Icons.share_outlined,
              label: 'Share',
              onTap: () async {
                Navigator.pop(ctx);
                final file = File(item.localPath);
                if (await file.exists()) {
                  await Share.shareXFiles([XFile(item.localPath)]);
                }
              },
            ),
            _OptionTile(
              icon: Icons.link,
              label: 'Copy link',
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: item.sourceUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
            ),
            _OptionTile(
              icon: Icons.folder_outlined,
              label: 'View File Location',
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(item.localPath)),
                );
              },
            ),
            _OptionTile(
              icon: Icons.delete_outline,
              label: 'Delete',
              color: AppColors.error,
              onTap: () async {
                Navigator.pop(ctx);
                final targets = await _deletionTargets(item);
                for (final path in targets) {
                  final file = File(path);
                  if (await file.exists()) {
                    try {
                      await file.delete();
                    } catch (_) {
                      // Continue best-effort cleanup for all possible copies.
                    }
                  }
                }
                await ref.read(downloadHistoryProvider.notifier).remove(item.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Deleted from app and gallery files')),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.visible = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return ListTile(
      leading: Icon(icon, color: color ?? AppColors.textPrimary),
      title: Text(
        label,
        style: GoogleFonts.poppins(
          color: color ?? AppColors.textPrimary,
          fontSize: 15,
        ),
      ),
      onTap: onTap,
    );
  }
}

Future<bool> _openOnInstagram(String sourceUrl) async {
  final raw = sourceUrl.trim();
  if (raw.isEmpty) return false;

  final webUri = Uri.tryParse(raw);
  if (webUri == null) return false;

  // Prefer opening in Instagram app when possible.
  final path = webUri.path.isEmpty ? '/' : webUri.path;
  final appUri = Uri.parse('instagram://media?url=${Uri.encodeComponent(raw)}');
  final httpsUri = webUri.hasScheme
      ? webUri
      : Uri.parse('https://www.instagram.com$path');

  try {
    if (await canLaunchUrl(appUri)) {
      final ok = await launchUrl(appUri, mode: LaunchMode.externalApplication);
      if (ok) return true;
    }
  } catch (_) {}

  try {
    final ok = await launchUrl(
      httpsUri,
      mode: LaunchMode.externalApplication,
    );
    if (ok) return true;
  } catch (_) {}

  try {
    return await launchUrl(
      httpsUri,
      mode: LaunchMode.platformDefault,
    );
  } catch (_) {
    return false;
  }
}

Future<List<String>> _deletionTargets(DownloadItem item) async {
  final paths = <String>{item.localPath};

  if (Platform.isAndroid) {
    final fileName = item.fileName;
    // Common public folders where media may be copied or scanned from.
    final roots = <String>[
      '/storage/emulated/0/Pictures/${AppConstants.appName}',
      '/storage/emulated/0/DCIM/${AppConstants.appName}',
      '/storage/emulated/0/Movies/${AppConstants.appName}',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/Movies',
    ];

    for (final root in roots) {
      paths.add('$root/$fileName');
    }
  }

  return paths.toList();
}

Future<DownloadSortOption?> showSortDialog(BuildContext context) {
  var selected = DownloadSortOption.downloadTime;
  return showDialog<DownloadSortOption>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: AppColors.darkSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              'Sort by:',
              style: GoogleFonts.poppins(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<DownloadSortOption>(
                  value: DownloadSortOption.downloadTime,
                  groupValue: selected,
                  onChanged: (v) => setState(() => selected = v!),
                  title: Text(
                    'Download Time',
                    style: GoogleFonts.poppins(color: AppColors.textPrimary),
                  ),
                  activeColor: AppColors.accent,
                ),
                RadioListTile<DownloadSortOption>(
                  value: DownloadSortOption.fileSize,
                  groupValue: selected,
                  onChanged: (v) => setState(() => selected = v!),
                  title: Text(
                    'File Size',
                    style: GoogleFonts.poppins(color: AppColors.textPrimary),
                  ),
                  activeColor: AppColors.accent,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.poppins(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, selected),
                child: Text('Confirm', style: GoogleFonts.poppins(color: AppColors.accent)),
              ),
            ],
          );
        },
      );
    },
  );
}
