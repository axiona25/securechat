import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

/// Scudo + lucchetto con pulse e breath, identico alla tab Sicurezza.
/// [size] è il lato del box esterno (default 180, come nella tab Sicurezza).
class SecurityShieldAnimatedLogo extends StatelessWidget {
  const SecurityShieldAnimatedLogo({
    super.key,
    required this.pulseController,
    required this.breathController,
    this.size = 180,
    this.accentColor = AppColors.primary,
  });

  final AnimationController pulseController;
  final AnimationController breathController;
  final double size;
  final Color accentColor;

  static const double _baseOuter = 180;

  @override
  Widget build(BuildContext context) {
    final scale = size / _baseOuter;
    final shieldW = 100.0 * scale;
    final shieldH = 120.0 * scale;
    final maxRadius = 85.0 * scale;
    final pulseStroke = 2.0 * scale;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: pulseController,
            builder: (context, child) => CustomPaint(
              size: Size(size, size),
              painter: SecurityShieldPulseCirclesPainter(
                progress: pulseController.value,
                color: accentColor,
                maxRadius: maxRadius,
                strokeWidth: pulseStroke,
              ),
            ),
          ),
          AnimatedBuilder(
            animation: breathController,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(breathController.value);
              final s = 0.95 + (1.05 - 0.95) * t;
              return Transform.scale(scale: s, child: child);
            },
            child: CustomPaint(
              size: Size(shieldW, shieldH),
              painter: SecurityShieldLockPainter(color: accentColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cerchi concentrici espandenti (pulse).
class SecurityShieldPulseCirclesPainter extends CustomPainter {
  SecurityShieldPulseCirclesPainter({
    required this.progress,
    required this.color,
    required this.maxRadius,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final double maxRadius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const circleCount = 3;
    for (var i = 0; i < circleCount; i++) {
      final phase = (progress + i / circleCount) % 1.0;
      final curve = Curves.easeOut.transform(phase);
      final radius = maxRadius * curve;
      final opacity = (1.0 - curve) * 0.28;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant SecurityShieldPulseCirclesPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.maxRadius != maxRadius ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Scudo con lucchetto.
class SecurityShieldLockPainter extends CustomPainter {
  SecurityShieldLockPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 120);
    const w = 100.0;
    const h = 120.0;
    final centerX = w / 2;

    final shieldPath = Path()
      ..moveTo(centerX, 6)
      ..quadraticBezierTo(w + 8, 6, w * 0.92, h * 0.22)
      ..lineTo(w * 0.92, h * 0.55)
      ..quadraticBezierTo(w * 0.92, h * 0.72, centerX, h * 0.88)
      ..quadraticBezierTo(w * 0.08, h * 0.72, w * 0.08, h * 0.55)
      ..lineTo(w * 0.08, h * 0.22)
      ..quadraticBezierTo(-8, 6, centerX, 6)
      ..close();

    final shieldPaint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;
    canvas.drawPath(shieldPath, shieldPaint);

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawPath(shieldPath, strokePaint);

    final lockLeft = centerX - 14;
    final lockTop = h * 0.38;
    const lockW = 28.0;
    const lockH = 22.0;
    final lockPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(lockLeft, lockTop + 10, lockW, lockH),
        const Radius.circular(4),
      ));
    canvas.drawPath(lockPath, strokePaint);
    canvas.drawPath(
      lockPath,
      Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );

    final shackleRect = Rect.fromLTWH(lockLeft - 2, lockTop - 4, lockW + 4, 18);
    canvas.drawArc(shackleRect, math.pi, math.pi, false, strokePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SecurityShieldLockPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
