import 'package:flutter/material.dart';

import '../core/constants.dart';

class QualitySelector extends StatelessWidget {
  const QualitySelector({
    super.key,
    required this.qualities,
    required this.selectedQuality,
    required this.onQualitySelected,
    this.label = 'Quality',
  });

  final List<int> qualities;
  final int selectedQuality;
  final ValueChanged<int> onQualitySelected;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (qualities.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: qualities.map((quality) {
            final selected = quality == selectedQuality;
            return ChoiceChip(
              label: Text('${quality}p'),
              selected: selected,
              onSelected: (_) => onQualitySelected(quality),
              selectedColor: AppColors.accent.withOpacity(0.2),
              backgroundColor: AppColors.darkCard,
              labelStyle: TextStyle(
                color: selected ? AppColors.accent : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              side: BorderSide(
                color: selected ? AppColors.accent : AppColors.darkBorder,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class FormatSelector extends StatelessWidget {
  const FormatSelector({
    super.key,
    required this.formats,
    required this.selectedFormat,
    required this.onFormatSelected,
  });

  final List<String> formats;
  final String selectedFormat;
  final ValueChanged<String> onFormatSelected;

  @override
  Widget build(BuildContext context) {
    if (formats.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Format',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: formats.map((format) {
            final selected = format == selectedFormat;
            return ChoiceChip(
              label: Text(format.toUpperCase()),
              selected: selected,
              onSelected: (_) => onFormatSelected(format),
              selectedColor: AppColors.accent.withOpacity(0.2),
              backgroundColor: AppColors.darkCard,
              labelStyle: TextStyle(
                color: selected ? AppColors.accent : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              side: BorderSide(
                color: selected ? AppColors.accent : AppColors.darkBorder,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
