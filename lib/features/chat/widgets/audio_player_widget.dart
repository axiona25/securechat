import 'dart:io';
import 'package:flutter/material.dart';

class AudioPlayerWidget extends StatelessWidget {
  final String messageId;
  final String? audioUrl;
  final File? localFile;
  final bool isMe;
  final String createdAt;
  final int durationSec;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double speed;
  final VoidCallback onTap;
  final VoidCallback onSpeedTap;

  const AudioPlayerWidget({
    Key? key,
    required this.messageId,
    this.audioUrl,
    this.localFile,
    required this.isMe,
    required this.createdAt,
    this.durationSec = 0,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.speed,
    required this.onTap,
    required this.onSpeedTap,
  }) : super(key: key);

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    String dateLabel = 'Audio';
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      dateLabel =
          'Audio del ${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    } catch (_) {}

    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    final totalDuration = duration.inSeconds > 0
        ? _fmt(duration)
        : durationSec > 0
            ? _fmt(Duration(seconds: durationSec))
            : '0:00';

    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFFE0E0E0),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.headphones_rounded,
                color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFF3A6AB0),
                size: 18,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  dateLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isMe ? const Color(0xFF2ABFBF) : const Color(0xFF1A2B4A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Color(0xFF2ABFBF),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        backgroundColor: Colors.grey[200],
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2ABFBF)),
                        minHeight: 4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isPlaying ? _fmt(position) : '0:00',
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                        Text(
                          totalDuration,
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSpeedTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${speed}x',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2ABFBF),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
