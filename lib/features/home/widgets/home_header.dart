import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/widgets/user_avatar_widget.dart';
import '../../../core/l10n/app_localizations.dart';

class HomeHeader extends StatelessWidget {
  final String? userAvatarUrl;
  final String? firstName;
  final String? lastName;
  final int notificationCount;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onAvatarTap;
  final bool isLockedMode;
  final Listenable? lockAnimation;
  final VoidCallback? onLockTap;

  const HomeHeader({
    super.key,
    this.userAvatarUrl,
    this.firstName,
    this.lastName,
    this.notificationCount = 0,
    this.onNotificationTap,
    this.onAvatarTap,
    this.isLockedMode = false,
    this.lockAnimation,
    this.onLockTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Image.asset(
            AppConstants.imgIcona,
            width: 40,
            height: 40,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      AppConstants.imgTestoLogo,
                      width: 130,
                      height: 22,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      AppLocalizations.of(context)?.t('app_subtitle') ?? AppConstants.appTagline,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
                if (isLockedMode && lockAnimation != null && onLockTap != null) ...[
                  const SizedBox(width: 8),
                  AnimatedBuilder(
                    animation: lockAnimation!,
                    builder: (context, child) {
                      final value = (lockAnimation as Animation<double>).value;
                      final pulse = 0.92 + (value * 0.12);
                      final glow = value;
                      return GestureDetector(
                        onTap: onLockTap,
                        child: Transform.scale(
                          scale: pulse,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF2ABFBF).withOpacity(0.15 + glow * 0.25),
                                  blurRadius: 4 + glow * 8,
                                  spreadRadius: 0,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.lock_rounded,
                              color: Color(0xFF2ABFBF),
                              size: 20,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          UserAvatarWidget(
            avatarUrl: userAvatarUrl,
            firstName: firstName,
            lastName: lastName,
            size: 42,
            borderWidth: 2,
            borderColor: AppColors.teal300,
            onTap: onAvatarTap,
          ),
        ],
      ),
    );
  }
}
