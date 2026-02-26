import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

class ImagePreviewScreen extends StatefulWidget {
  final File imageFile;
  final String fileName;

  const ImagePreviewScreen({
    super.key,
    required this.imageFile,
    required this.fileName,
  });

  static Future<String?> show(BuildContext context, File imageFile, String fileName) {
    return Navigator.of(context).push<String?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImagePreviewScreen(
          imageFile: imageFile,
          fileName: fileName,
        ),
      ),
    );
  }

  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  final TextEditingController _captionController = TextEditingController();

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.navy900,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    icon: const Icon(Icons.close_rounded,
                        color: AppColors.textOnPrimary, size: 26),
                  ),
                  const Spacer(),
                  Text(
                    widget.fileName,
                    style: TextStyle(
                      color: AppColors.textOnPrimary.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Center(
                  child: Image.file(
                    widget.imageFile,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: MediaQuery.of(context).viewPadding.bottom + 12,
              ),
              color: AppColors.navy900.withValues(alpha: 0.9),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.textOnPrimary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _captionController,
                        style: const TextStyle(
                          color: AppColors.textOnPrimary,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Add a caption...',
                          hintStyle: TextStyle(
                            color: AppColors.textOnPrimary.withValues(alpha: 0.4),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop(_captionController.text);
                    },
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.4),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.send_rounded,
                        color: AppColors.textOnPrimary,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
