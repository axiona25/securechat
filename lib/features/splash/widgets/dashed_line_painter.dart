import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

class DashedLinePainter extends CustomPainter {
  final double progress;
  final Color color;

  DashedLinePainter({
    required this.progress,
    this.color = AppColors.teal300,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const dashWidth = 6.0;
    const dashSpace = 4.0;
    final totalWidth = size.width * progress;

    double startX = 0;
    final y = size.height / 2;

    while (startX < totalWidth) {
      final endX = (startX + dashWidth).clamp(0.0, totalWidth);
      canvas.drawLine(
        Offset(startX, y),
        Offset(endX, y),
        paint,
      );
      startX += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(DashedLinePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
