import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../constants/app_constants.dart';

enum SocialProvider { google, apple }

class SocialLoginButton extends StatelessWidget {
  final SocialProvider provider;
  final VoidCallback? onPressed;

  const SocialLoginButton({
    super.key,
    required this.provider,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.divider,
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.navy900.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildIcon(),
              const SizedBox(width: 10),
              Text(
                provider == SocialProvider.google ? 'Google' : 'Apple',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIcon() {
    final String assetPath = provider == SocialProvider.google
        ? AppConstants.imgGoogleIcon
        : AppConstants.imgAppleIcon;
    const double size = 22;
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
      ),
    );
  }
}
