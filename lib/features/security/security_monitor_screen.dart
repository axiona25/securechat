// lib/features/security/security_monitor_screen.dart
//
// AXPHONE — Security Monitor Screen
// Design system: light theme, AppColors, AppTheme.
// Si integra nella SecurityScreen esistente come sotto-vista
// o come schermata navigabile dal tab Security.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/services/security_service.dart';

class SecurityMonitorScreen extends StatefulWidget {
  const SecurityMonitorScreen({super.key});

  @override
  State<SecurityMonitorScreen> createState() =>
      _SecurityMonitorScreenState();
}

class _SecurityMonitorScreenState extends State<SecurityMonitorScreen>
    with TickerProviderStateMixin {
  final _security = SecurityService();

  late AnimationController _pulseController;
  late AnimationController _breathController;
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
    _particlesController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _breathController.dispose();
    _particlesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SecurityStatus>(
      stream: _security.statusStream,
      initialData: _security.currentStatus,
      builder: (context, snapshot) {
        final status = snapshot.data ?? _security.currentStatus;
        return _buildScaffold(context, status);
      },
    );
  }

  Widget _buildScaffold(BuildContext context, SecurityStatus status) {
    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        title: const Text('Monitor di sicurezza'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: _buildContent(context, status),
    );
  }

  Widget _buildContent(BuildContext context, SecurityStatus status) {
    final config = _levelConfig(status.level);
    return Stack(
      children: [
        // Matrix lines — stesso stile SecurityScreen esistente
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _particlesController,
            builder: (context, _) => CustomPaint(
              painter: _MatrixLinesPainter(
                progress: _particlesController.value,
                color: AppColors.primary.withValues(alpha: 0.06),
              ),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _buildStatusHero(status, config),
              const SizedBox(height: 20),
              _buildScoreCard(status, config),
              const SizedBox(height: 16),
              _buildChecksGrid(status),
              if (status.events.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildEventsList(status),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ─── HERO STATUS ──────────────────────────────

  Widget _buildStatusHero(SecurityStatus status, _LevelConfig config) {
    return AnimatedBuilder(
      animation: _breathController,
      builder: (_, child) {
        final t = Curves.easeInOut.transform(_breathController.value);
        final scale = status.level != ThreatLevel.safe ? 0.97 + 0.03 * t : 1.0;
        return Transform.scale(scale: scale, child: child);
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: config.accentColor.withValues(alpha: 0.35),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: config.accentColor.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) => CustomPaint(
                      size: const Size(120, 120),
                      painter: _PulseCirclesPainter(
                        progress: _pulseController.value,
                        color: config.accentColor,
                      ),
                    ),
                  ),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          config.accentColor.withValues(alpha: 0.18),
                          config.accentColor.withValues(alpha: 0.08),
                        ],
                      ),
                      border: Border.all(
                        color: config.accentColor.withValues(alpha: 0.5),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(config.icon, color: config.accentColor, size: 30),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              config.label,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: config.accentColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              config.subtitle,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (status.isMonitoring) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6, height: 6,
                          decoration: const BoxDecoration(
                            color: AppColors.success, shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'Monitoraggio attivo',
                          style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600,
                            color: AppColors.success,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  'Scan: ${_formatTime(status.lastCheck)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textDisabled),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── SCORE CARD ───────────────────────────────

  Widget _buildScoreCard(SecurityStatus status, _LevelConfig config) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy900.withValues(alpha: 0.05),
            blurRadius: 12, offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Threat Score',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
              Text('${status.totalScore}/100',
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold,
                      color: config.accentColor)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: status.totalScore / 100,
              minHeight: 8,
              backgroundColor: AppColors.bgIce,
              valueColor: AlwaysStoppedAnimation<Color>(config.accentColor),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _scoreLegend('0–24', AppColors.success, 'Sicuro'),
              _scoreLegend('25–59', AppColors.warning, 'Attenzione'),
              _scoreLegend('60–100', AppColors.error, 'Critico'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scoreLegend(String range, Color color, String label) {
    return Row(
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
            Text(range, style: const TextStyle(fontSize: 9, color: AppColors.textDisabled)),
          ],
        ),
      ],
    );
  }

  // ─── CHECKS GRID ──────────────────────────────

  Widget _buildChecksGrid(SecurityStatus status) {
    final recentTypes = status.events
        .where((e) => e.timestamp
            .isAfter(DateTime.now().subtract(const Duration(minutes: 10))))
        .map((e) => e.type)
        .toSet();

    final checks = [
      (ThreatType.appTampering,       Icons.verified_user_outlined,      'Integrità App'),
      (ThreatType.jailbreakRoot,      Icons.phonelink_lock_outlined,     'Jailbreak/Root'),
      (ThreatType.debuggerAttached,   Icons.bug_report_outlined,         'Debugger'),
      (ThreatType.frideaHook,         Icons.extension_outlined,          'Hook Framework'),
      (ThreatType.suspiciousNetwork,  Icons.wifi_tethering_outlined,     'Rete'),
      (ThreatType.microphoneHijack,   Icons.mic_none_outlined,           'Microfono'),
      (ThreatType.cameraHijack,       Icons.camera_alt_outlined,         'Fotocamera'),
      (ThreatType.clipboardHijack,    Icons.content_paste_outlined,      'Clipboard'),
      (ThreatType.overlayAttack,      Icons.layers_outlined,             'Overlay'),
      (ThreatType.accessibilityAbuse, Icons.accessibility_new_outlined,  'Accessibilità'),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy900.withValues(alpha: 0.05),
            blurRadius: 12, offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Controlli di Sicurezza',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.8,
            children: checks
                .map((c) => _buildCheckTile(c.$1, c.$2, c.$3, recentTypes.contains(c.$1)))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckTile(ThreatType _, IconData icon, String label, bool triggered) {
    final ok = !triggered;
    final color = ok ? AppColors.success : AppColors.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textTertiary),
          const SizedBox(width: 4),
          Icon(
            ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
            color: color, size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(ok ? 'OK' : 'ALLERTA',
                    style: TextStyle(
                        fontSize: 9, fontWeight: FontWeight.w700, color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── EVENTS LIST ──────────────────────────────

  Widget _buildEventsList(SecurityStatus status) {
    final recent = status.events.reversed.take(20).toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy900.withValues(alpha: 0.05),
            blurRadius: 12, offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Log Minacce',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          ...recent.map(_buildEventTile),
        ],
      ),
    );
  }

  Widget _buildEventTile(ThreatEvent event) {
    final color = event.score >= 60
        ? AppColors.error
        : event.score >= 30
            ? AppColors.warning
            : AppColors.info;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12), shape: BoxShape.circle,
            ),
            child: Center(
              child: Text('${event.score}',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold, color: color)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.description,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500),
                    maxLines: 2),
                const SizedBox(height: 2),
                Text(_formatTime(event.timestamp),
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textDisabled)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── HELPERS ──────────────────────────────────

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s fa';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m fa';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  _LevelConfig _levelConfig(ThreatLevel level) {
    switch (level) {
      case ThreatLevel.safe:
        return const _LevelConfig(
          accentColor: AppColors.success,
          icon: Icons.verified_user_outlined,
          label: 'Dispositivo Sicuro',
          subtitle: 'Nessuna minaccia rilevata',
        );
      case ThreatLevel.warning:
        return const _LevelConfig(
          accentColor: AppColors.warning,
          icon: Icons.warning_amber_outlined,
          label: 'Attenzione',
          subtitle: 'Attività sospetta rilevata',
        );
      case ThreatLevel.critical:
        return const _LevelConfig(
          accentColor: AppColors.error,
          icon: Icons.gpp_bad_outlined,
          label: 'Minaccia Critica',
          subtitle: 'Azioni di protezione attive',
        );
    }
  }
}

// ─── CONFIG LIVELLO ───────────────────────────

class _LevelConfig {
  final Color accentColor;
  final IconData icon;
  final String label;
  final String subtitle;
  const _LevelConfig({
    required this.accentColor,
    required this.icon,
    required this.label,
    required this.subtitle,
  });
}

// ─── PAINTERS (stile identico a SecurityScreen) ──

class _PulseCirclesPainter extends CustomPainter {
  const _PulseCirclesPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const maxRadius = 55.0;
    const circleCount = 3;
    for (var i = 0; i < circleCount; i++) {
      final phase = (progress + i / circleCount) % 1.0;
      final curve = Curves.easeOut.transform(phase);
      final radius = maxRadius * curve;
      final opacity = (1.0 - curve) * 0.22;
      canvas.drawCircle(
        center, radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PulseCirclesPainter old) =>
      old.progress != progress || old.color != color;
}

class _MatrixLinesPainter extends CustomPainter {
  const _MatrixLinesPainter({required this.progress, required this.color});
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
        final segLen = 8.0 + rnd.nextDouble() * 12;
        final alpha = 0.06 + rnd.nextDouble() * 0.10;
        canvas.drawLine(
          Offset(x, y), Offset(x, y + segLen),
          Paint()
            ..color = color.withValues(alpha: alpha)
            ..strokeWidth = 1.2
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatrixLinesPainter old) =>
      old.progress != progress || old.color != color;
}
