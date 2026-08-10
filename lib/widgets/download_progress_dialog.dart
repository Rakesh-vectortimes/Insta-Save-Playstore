import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../services/download_service.dart';

class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({
    super.key,
    required this.progress,
    this.message = 'Downloading...',
  });

  final FileDownloadProgress? progress;
  final String message;

  @override
  Widget build(BuildContext context) {
    final fraction = progress?.fraction ?? 0;
    final percent = (fraction * 100).clamp(0, 100).toInt();

    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress != null && progress!.total > 0 ? fraction : null,
              color: AppColors.primary,
              backgroundColor: Colors.grey.shade200,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 8),
            Text(
              progress != null && progress!.total > 0 ? '$percent%' : 'Starting...',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> show(
    BuildContext context, {
    required ValueNotifier<FileDownloadProgress?> progressNotifier,
    String message = 'Downloading...',
    ValueNotifier<String>? messageNotifier,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return ValueListenableBuilder<FileDownloadProgress?>(
          valueListenable: progressNotifier,
          builder: (context, progress, _) {
            if (messageNotifier == null) {
              return DownloadProgressDialog(
                progress: progress,
                message: message,
              );
            }
            return ValueListenableBuilder<String>(
              valueListenable: messageNotifier,
              builder: (context, dynamicMessage, _) {
                return DownloadProgressDialog(
                  progress: progress,
                  message: dynamicMessage,
                );
              },
            );
          },
        );
      },
    );
  }
}
