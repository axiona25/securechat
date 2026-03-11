import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Placeholder screen for the Security tab (Sicurezza) in the bottom nav.
/// Light theme, shield+lock with pulse and breath animations,
/// subtle matrix-style lines, and "Coming Soon" badge.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen>
    with TickerProviderStateMixin {
  static const Color _accent = AppColors.primary;
  static const Color _subtitleColor = AppColors.textSecondary;

  late AnimationController _pulseController;
  late AnimationController _breathController;
  late AnimationController _badgeFadeController;
  late AnimationController _particlesController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);
    _badgeFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _particlesController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _breathController.dispose();
    _badgeFadeController.dispose();
    _particlesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Stack(
      children: [
        // Subtle matrix-style falling lines (light theme)
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _particlesController,
            builder: (context, child) => CustomPaint(
              painter: _MatrixLinesPainter(
                progress: _particlesController.value,
                color: _accent.withValues(alpha: 0.08),
              ),
            ),
          ),
        ),
        // Content
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
                // Shield + lock with pulse and breath
                SizedBox(
                  width: 180,
                  height: 180,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) => CustomPaint(
                          size: const Size(180, 180),
                          painter: _PulseCirclesPainter(
                            progress: _pulseController.value,
                            color: _accent,
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _breathController,
                        builder: (context, child) {
                          final curve = Curves.easeInOut;
                          final t = curve.transform(_breathController.value);
                          final scale = 0.95 + (1.05 - 0.95) * t;
                          return Transform.scale(
                            scale: scale,
                            child: child,
                          );
                        },
                        child: CustomPaint(
                          size: const Size(100, 120),
                          painter: _ShieldLockPainter(color: _accent),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Protezione Avanzata',
                  style: theme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ) ?? const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Stiamo costruendo qualcosa di straordinario per proteggere '
                  'le tue conversazioni. Una nuova funzionalità di sicurezza '
                  'è in arrivo. 🔐',
                  style: theme.bodyMedium?.copyWith(
                    fontSize: 14,
                    color: _subtitleColor,
                    height: 1.5,
                  ) ?? const TextStyle(
                    fontSize: 14,
                    color: _subtitleColor,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                AnimatedBuilder(
                  animation: _badgeFadeController,
                  builder: (context, child) {
                    final curve = Curves.easeInOut;
                    final t = curve.transform(_badgeFadeController.value);
                    final opacity = 0.4 + (1.0 - 0.4) * t;
                    return Opacity(
                      opacity: opacity,
                      child: child,
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: _accent.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                    child: const Text(
                      'Coming Soon',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
    );
  }
}

/// Concentric circles that expand and fade (pulse effect).
class _PulseCirclesPainter extends CustomPainter {
  _PulseCirclesPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const maxRadius = 85.0;
    const circleCount = 3;
    for (var i = 0; i < circleCount; i++) {
      final phase = (progress + i / circleCount) % 1.0;
      final curve = Curves.easeOut.transform(phase);
      final radius = maxRadius * curve;
      final opacity = (1.0 - curve) * 0.28;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulseCirclesPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// Shield shape with lock (cyber style).
class _ShieldLockPainter extends CustomPainter {
  _ShieldLockPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final centerX = w / 2;

    // Shield path: rounded top, sides, bottom point
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

    // Lock body (rectangle + arc)
    final lockLeft = centerX - 14;
    final lockTop = h * 0.38;
    final lockW = 28.0;
    final lockH = 22.0;
    final lockPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(lockLeft, lockTop + 10, lockW, lockH),
        const Radius.circular(4),
      ));
    canvas.drawPath(lockPath, strokePaint);
    canvas.drawPath(lockPath, Paint()..color = color.withValues(alpha: 0.15)..style = PaintingStyle.fill);

    // Lock shackle (arc above body)
    final shackleRect = Rect.fromLTWH(lockLeft - 2, lockTop - 4, lockW + 4, 18);
    canvas.drawArc(shackleRect, math.pi, math.pi, false, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _ShieldLockPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

/// Falling vertical line segments (matrix-style).
class _MatrixLinesPainter extends CustomPainter {
  _MatrixLinesPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const lineCount = 24;
    final rnd = math.Random(42);
    for (var i = 0; i < lineCount; i++) {
      final x = (i / lineCount) * size.width + rnd.nextDouble() * 8;
      final segmentCount = 4 + rnd.nextInt(6);
      final step = size.height / 8;
      for (var s = 0; s < segmentCount; s++) {
        final offset = (progress + s * 0.15 + i * 0.03) % 1.0;
        final y = offset * (size.height + step * 2) - step;
        final segmentHeight = 8.0 + rnd.nextDouble() * 12;
        final alpha = 0.08 + rnd.nextDouble() * 0.12;
        final paint = Paint()
          ..color = color.withValues(alpha: alpha)
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(Offset(x, y), Offset(x, y + segmentHeight), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixLinesPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
