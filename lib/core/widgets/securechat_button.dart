import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class SecureChatButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool showArrow;
  final double? width;
  final double height;

  const SecureChatButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.showArrow = true,
    this.width,
    this.height = 56,
  });

  @override
  State<SecureChatButton> createState() => _SecureChatButtonState();
}

class _SecureChatButtonState extends State<SecureChatButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pressController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEnabled = widget.onPressed != null && !widget.isLoading;

    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: child,
        );
      },
      child: GestureDetector(
        onTapDown: isEnabled ? (_) => _pressController.forward() : null,
        onTapUp: isEnabled ? (_) => _pressController.reverse() : null,
        onTapCancel: isEnabled ? () => _pressController.reverse() : null,
        onTap: isEnabled ? widget.onPressed : null,
        child: Container(
          width: widget.width ?? double.infinity,
          height: widget.height,
          decoration: BoxDecoration(
            gradient: isEnabled ? AppColors.buttonGradient : null,
            color: isEnabled ? null : AppColors.textDisabled,
            borderRadius: BorderRadius.circular(16),
            boxShadow: isEnabled
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.isLoading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.textOnPrimary),
                  ),
                )
              else ...[
                Text(
                  widget.text,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textOnPrimary,
                    letterSpacing: 0.5,
                  ),
                ),
                if (widget.showArrow) ...[
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: AppColors.textOnPrimary,
                    size: 22,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
