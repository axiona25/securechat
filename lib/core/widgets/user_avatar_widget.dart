import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/avatar_cache_service.dart';

class UserAvatarWidget extends StatefulWidget {
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

  @override
  State<UserAvatarWidget> createState() => _UserAvatarWidgetState();
}

class _UserAvatarWidgetState extends State<UserAvatarWidget> {
  String? _previousUrl;

  String get _initials {
    if (widget.firstName != null && widget.firstName!.isNotEmpty) {
      final first = widget.firstName![0].toUpperCase();
      final last = (widget.lastName != null && widget.lastName!.isNotEmpty)
          ? widget.lastName![0].toUpperCase()
          : '';
      return '$first$last';
    }
    if (widget.displayName != null && widget.displayName!.isNotEmpty) {
      final parts = widget.displayName!.trim().split(' ');
      if (parts.length >= 2) {
        return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      }
      return widget.displayName!.length >= 2
          ? widget.displayName!.substring(0, 2).toUpperCase()
          : widget.displayName!.toUpperCase();
    }
    return '?';
  }

  String? _bustedUrl(int buster) {
    if (widget.avatarUrl == null) return null;
    if (buster == 0) return widget.avatarUrl;
    final sep = widget.avatarUrl!.contains('?') ? '&' : '?';
    return '${widget.avatarUrl}${sep}t=$buster';
  }

  void _evictIfChanged(String? newUrl) {
    // Evict sempre l'URL base quando cambia qualcosa
    if (widget.avatarUrl != null) {
      NetworkImage(widget.avatarUrl!).evict();
    }
    // Evict anche l'URL precedente (con o senza buster)
    if (_previousUrl != null && _previousUrl != newUrl) {
      NetworkImage(_previousUrl!).evict();
      final baseUrl = _previousUrl!.contains('?')
          ? _previousUrl!.substring(0, _previousUrl!.indexOf('?'))
          : _previousUrl!;
      NetworkImage(baseUrl).evict();
    }
    _previousUrl = newUrl;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AvatarCacheService.instance.cacheBuster,
      builder: (context, buster, __) {
        final url = _bustedUrl(buster);
        _evictIfChanged(url);

        Widget avatar;
        if (url != null) {
          avatar = Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: widget.borderWidth > 0
                  ? Border.all(
                      color: widget.borderColor ?? AppColors.teal300,
                      width: widget.borderWidth)
                  : null,
            ),
            child: ClipOval(
              child: Image.network(
                url,
                key: ValueKey('$url-$buster'),
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                headers: const {'Cache-Control': 'no-cache'},
                errorBuilder: (_, error, stack) => _initialsWidget(),
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return _initialsWidget();
                },
              ),
            ),
          );
        } else {
          avatar = Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: widget.borderWidth > 0
                  ? Border.all(
                      color: widget.borderColor ?? AppColors.teal300,
                      width: widget.borderWidth)
                  : null,
              color: AppColors.primary,
            ),
            child: Center(child: _initialsWidget()),
          );
        }

        if (widget.onTap != null) {
          return GestureDetector(onTap: widget.onTap, child: avatar);
        }
        return avatar;
      },
    );
  }

  Widget _initialsWidget() {
    return Text(
      _initials,
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.size * 0.35,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
  }
}
