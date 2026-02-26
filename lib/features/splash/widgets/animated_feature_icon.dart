import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

class AnimatedFeatureIcon extends StatelessWidget {
  final IconData icon;
  final IconData? overlayIcon;
  final Animation<double> animation;

  const AnimatedFeatureIcon({
    super.key,
    required this.icon,
    this.overlayIcon,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Transform.scale(
          scale: animation.value,
          child: Opacity(
            opacity: animation.value.clamp(0.0, 1.0),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.85),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.3),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    icon,
                    color: AppColors.primary,
                    size: 24,
                  ),
                  if (overlayIcon != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Icon(
                        overlayIcon,
                        color: AppColors.primary.withValues(alpha: 0.7),
                        size: 14,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
