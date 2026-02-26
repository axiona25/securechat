import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';

class FullscreenImageViewer extends StatelessWidget {
  final String imageUrl;
  final String? heroTag;

  const FullscreenImageViewer({
    super.key,
    required this.imageUrl,
    this.heroTag,
  });

  static void show(BuildContext context, String imageUrl, {String? heroTag}) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, _, _) => FullscreenImageViewer(
          imageUrl: imageUrl,
          heroTag: heroTag,
        ),
        transitionsBuilder: (_, animation, _, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarIconBrightness: Brightness.light,
    ));

    return Scaffold(
      backgroundColor: AppColors.navy900.withValues(alpha: 0.95),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                child: heroTag != null
                    ? Hero(
                        tag: heroTag!,
                        child: _buildImage(),
                      )
                    : _buildImage(),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: GestureDetector(
                onTap: () {
                  SystemChrome.setSystemUIOverlayStyle(
                    const SystemUiOverlayStyle(
                      statusBarIconBrightness: Brightness.dark,
                    ),
                  );
                  Navigator.of(context).pop();
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.navy900.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textOnPrimary,
                    size: 22,
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildActionButton(Icons.share_outlined, 'Share', () {}),
                  const SizedBox(width: 32),
                  _buildActionButton(Icons.download_outlined, 'Save', () {}),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage() {
    return Image.network(
      imageUrl,
      fit: BoxFit.contain,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Center(
          child: CircularProgressIndicator(
            value: progress.expectedTotalBytes != null
                ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                : null,
            color: AppColors.primary,
            strokeWidth: 2.5,
          ),
        );
      },
      errorBuilder: (_, _, _) => const Icon(
        Icons.broken_image_outlined,
        color: AppColors.textDisabled,
        size: 64,
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.textOnPrimary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppColors.textOnPrimary, size: 24),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textOnPrimary.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
