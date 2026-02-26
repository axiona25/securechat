import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/media_service.dart';

class FilePreviewWidget extends StatelessWidget {
  final PickedMedia media;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  const FilePreviewWidget({
    super.key,
    required this.media,
    required this.onSend,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _getFileColor().withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _getFileIcon(),
              color: _getFileColor(),
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  media.fileName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  media.fileSizeFormatted,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textDisabled,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, color: AppColors.textDisabled, size: 20),
          ),
          GestureDetector(
            onTap: onSend,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send_rounded, color: AppColors.textOnPrimary, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Color _getFileColor() {
    final parts = media.fileName.split('.');
    final ext = parts.length > 1 ? parts.last.toLowerCase() : '';
    switch (ext) {
      case 'pdf':
        return const Color(0xFFE53935);
      case 'doc':
      case 'docx':
        return const Color(0xFF2196F3);
      case 'xls':
      case 'xlsx':
        return const Color(0xFF4CAF50);
      case 'zip':
      case 'rar':
        return const Color(0xFFFF9800);
      case 'ppt':
      case 'pptx':
        return const Color(0xFFFF5722);
      default:
        return AppColors.textSecondary;
    }
  }

  IconData _getFileIcon() {
    final parts = media.fileName.split('.');
    final ext = parts.length > 1 ? parts.last.toLowerCase() : '';
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'doc':
      case 'docx':
        return Icons.description_outlined;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_outlined;
      case 'zip':
      case 'rar':
        return Icons.folder_zip_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}
