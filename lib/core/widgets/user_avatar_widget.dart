import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/avatar_cache_service.dart';

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

  String? get _bustedUrl {
    if (avatarUrl == null) return null;
    final buster = AvatarCacheService.instance.cacheBuster.value;
    if (buster == 0) return avatarUrl;
    final sep = avatarUrl!.contains('?') ? '&' : '?';
    return '$avatarUrl${sep}t=$buster';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AvatarCacheService.instance.cacheBuster,
      builder: (context, _, __) {
        final url = _bustedUrl;
        final avatar = Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: borderWidth > 0
                ? Border.all(color: borderColor ?? AppColors.teal300, width: borderWidth)
                : null,
            color: url == null ? AppColors.primary : null,
            image: url != null
                ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
                : null,
          ),
          child: url == null
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
      },
    );
  }
}
