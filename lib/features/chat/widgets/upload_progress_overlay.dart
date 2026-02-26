import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

class UploadProgressOverlay extends StatelessWidget {
  final double progress;
  final String? fileName;
  final VoidCallback? onCancel;

  const UploadProgressOverlay({
    super.key,
    required this.progress,
    this.fileName,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy900.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3,
                  backgroundColor: AppColors.divider,
                  color: AppColors.primary,
                ),
                Text(
                  '${(progress * 100).toInt()}%',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName ?? 'Uploading...',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: AppColors.divider,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
          if (onCancel != null) ...[
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onCancel,
              child: const Icon(
                Icons.close_rounded,
                color: AppColors.textDisabled,
                size: 20,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
