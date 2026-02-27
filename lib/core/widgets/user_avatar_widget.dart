import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class UserAvatarWidget extends StatelessWidget {
  final String? avatarUrl;
  final String? firstName;
  final String? lastName;
  final String? displayName;
  final double size;
  final VoidCallback? onTap;
  final double borderWidth;
  final Color? borderColor;

  const UserAvatarWidget({
    super.key,
    this.avatarUrl,
    this.firstName,
    this.lastName,
    this.displayName,
    this.size = 40,
    this.onTap,
    this.borderWidth = 0,
    this.borderColor,
  });

  String get _initials {
    if (firstName != null && firstName!.isNotEmpty) {
      final first = firstName![0].toUpperCase();
      final last = (lastName != null && lastName!.isNotEmpty)
          ? lastName![0].toUpperCase()
          : '';
      return '$first$last';
    }
    if (displayName != null && displayName!.isNotEmpty) {
      final parts = displayName!.trim().split(' ');
      if (parts.length >= 2) {
        return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      }
      return displayName!.length >= 2
          ? displayName!.substring(0, 2).toUpperCase()
          : displayName!.toUpperCase();
    }
    return '?';
  }

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderWidth > 0
            ? Border.all(color: borderColor ?? AppColors.teal300, width: borderWidth)
            : null,
        color: avatarUrl == null ? AppColors.primary : null,
        image: avatarUrl != null
            ? DecorationImage(image: NetworkImage(avatarUrl!), fit: BoxFit.cover)
            : null,
      ),
      child: avatarUrl == null
          ? Center(
              child: Text(
                _initials,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.35,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            )
          : null,
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: avatar);
    }
    return avatar;
  }
}
