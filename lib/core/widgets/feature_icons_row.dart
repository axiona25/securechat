import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Riga di 3 icone feature (lucchetto+scudo, chat, scudo+check)
/// con linee tratteggiate tra loro. Usata nella splash e nella login.
class FeatureIconsRow extends StatelessWidget {
  final double iconSize;

  const FeatureIconsRow({
    super.key,
    this.iconSize = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildIcon(Icons.lock_outline, Icons.shield_outlined),
        _buildDashedLine(),
        _buildIcon(Icons.chat_bubble_outline, null),
        _buildDashedLine(),
        _buildIcon(Icons.verified_user_outlined, null),
      ],
    );
  }

  Widget _buildIcon(IconData mainIcon, IconData? overlayIcon) {
    return Container(
      width: iconSize,
      height: iconSize,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.85),
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.teal300.withValues(alpha: 0.4),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(mainIcon, color: AppColors.primary, size: iconSize * 0.48),
          if (overlayIcon != null)
            Positioned(
              right: iconSize * 0.12,
              bottom: iconSize * 0.12,
              child: Icon(
                overlayIcon,
                color: AppColors.primary.withValues(alpha: 0.6),
                size: iconSize * 0.28,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDashedLine() {
    return SizedBox(
      width: 36,
      height: 2,
      child: CustomPaint(
        painter: _SmallDashedPainter(),
      ),
    );
  }
}

class _SmallDashedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.teal300.withValues(alpha: 0.5)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const dashWidth = 4.0;
    const dashSpace = 3.0;
    double startX = 0;
    final y = size.height / 2;

    while (startX < size.width) {
      final endX = (startX + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(startX, y), Offset(endX, y), paint);
      startX += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
