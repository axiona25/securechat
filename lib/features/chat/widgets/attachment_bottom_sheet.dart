import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

enum AttachmentType { gallery, camera, video, file, location, contact }

class AttachmentBottomSheet extends StatelessWidget {
  final ValueChanged<AttachmentType> onSelected;

  const AttachmentBottomSheet({
    super.key,
    required this.onSelected,
  });

  static Future<AttachmentType?> show(BuildContext context) {
    return showModalBottomSheet<AttachmentType>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => AttachmentBottomSheet(
        onSelected: (type) => Navigator.of(ctx).pop(type),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Share',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildOption(
                  icon: Icons.photo_library_outlined,
                  label: 'Gallery',
                  color: AppColors.primary,
                  type: AttachmentType.gallery,
                ),
                _buildOption(
                  icon: Icons.camera_alt_outlined,
                  label: 'Camera',
                  color: AppColors.blue500,
                  type: AttachmentType.camera,
                ),
                _buildOption(
                  icon: Icons.videocam_outlined,
                  label: 'Video',
                  color: const Color(0xFF9C27B0),
                  type: AttachmentType.video,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildOption(
                  icon: Icons.insert_drive_file_outlined,
                  label: 'File',
                  color: AppColors.warning,
                  type: AttachmentType.file,
                ),
                _buildOption(
                  icon: Icons.location_on_outlined,
                  label: 'Location',
                  color: AppColors.online,
                  type: AttachmentType.location,
                ),
                _buildOption(
                  icon: Icons.person_outline_rounded,
                  label: 'Contact',
                  color: AppColors.blue700,
                  type: AttachmentType.contact,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildOption({
    required IconData icon,
    required String label,
    required Color color,
    required AttachmentType type,
  }) {
    return GestureDetector(
      onTap: () => onSelected(type),
      child: SizedBox(
        width: 80,
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
