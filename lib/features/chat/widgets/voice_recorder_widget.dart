import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/audio_service.dart';

class VoiceRecorderWidget extends StatefulWidget {
  final VoidCallback onCancel;
  final ValueChanged<String> onSend;

  const VoiceRecorderWidget({
    super.key,
    required this.onCancel,
    required this.onSend,
  });

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget>
    with SingleTickerProviderStateMixin {
  final AudioService _audio = AudioService();
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _durationSub;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _startRecording();
  }

  Future<void> _startRecording() async {
    final started = await _audio.startRecording();
    if (!started && mounted) {
      widget.onCancel();
      return;
    }

    _durationSub = _audio.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
  }

  Future<void> _sendRecording() async {
    final file = await _audio.stopRecording();
    if (file != null) {
      widget.onSend(file.path);
    } else {
      widget.onCancel();
    }
  }

  Future<void> _cancelRecording() async {
    await _audio.cancelRecording();
    widget.onCancel();
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewPadding.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: AppColors.navy900.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _cancelRecording,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.error,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(
                          alpha: 0.5 + (_pulseController.value * 0.5),
                        ),
                        shape: BoxShape.circle,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 10),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: CustomPaint(
                      painter: _WaveformPainter(
                        progress: _pulseController.value,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          GestureDetector(
            onTap: _sendRecording,
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.send_rounded,
                color: AppColors.textOnPrimary,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double progress;

  _WaveformPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.4)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final barCount = (size.width / 5).floor();
    for (int i = 0; i < barCount; i++) {
      final x = i * 5.0;
      final normalized = (i / barCount + progress) % 1.0;
      final height = (size.height * 0.3) +
          (size.height * 0.7 * (0.5 + 0.5 * _sin(normalized * 3.14159 * 2)));
      final y1 = (size.height - height) / 2;
      final y2 = y1 + height;
      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
    }
  }

  double _sin(double x) {
    x = x % (2 * 3.14159);
    if (x > 3.14159) x -= 2 * 3.14159;
    return x - (x * x * x) / 6 + (x * x * x * x * x) / 120;
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
