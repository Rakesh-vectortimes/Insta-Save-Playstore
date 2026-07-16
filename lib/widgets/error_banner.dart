import 'package:flutter/material.dart';

import '../core/constants.dart';

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.scopeLimited = false,
    this.retryable = false,
    this.onRetry,
  });

  final String message;
  final bool scopeLimited;
  final bool retryable;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scopeLimited
            ? Colors.orange.withOpacity(0.12)
            : AppColors.error.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scopeLimited
              ? Colors.orange.withOpacity(0.35)
              : AppColors.error.withOpacity(0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                scopeLimited ? Icons.info_outline : Icons.error_outline,
                color: scopeLimited ? Colors.orange : AppColors.error,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    height: 1.4,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          if (retryable && onRetry != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try again'),
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
