// lib/features/security/security_monitor_screen.dart
//
// AXPHONE — Monitor di sicurezza (contenuto principale del tab Sicurezza).

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/services/security_service.dart';
import '../../main.dart' show securityEnabledNotifier;
import 'widgets/security_shield_animated_logo.dart';

class SecurityMonitorScreen extends StatefulWidget {
  const SecurityMonitorScreen({super.key});

  @override
  State<SecurityMonitorScreen> createState() =>
      _SecurityMonitorScreenState();
}

class _SecurityMonitorScreenState extends State<SecurityMonitorScreen>
    with TickerProviderStateMixin {
  final _security = SecurityService();

  /// Stesso navy delle pagine impostazioni (Account, Privacy).
  static const Color _navyHeader = Color(0xFF1A2B4A);

  /// Logo scudo più grande della tab Sicurezza (180).
  static const double _heroLogoSize = 232;

  late AnimationController _pulseController;
  late AnimationController _breathController;
  late AnimationController _particlesController;

  void _onSecurityEnabledChanged() => _syncSecurityAnimations();

  /// Ripete o ferma pulse / breath / matrix in base a [securityEnabledNotifier].
  void _syncSecurityAnimations() {
    if (!mounted) return;
    if (securityEnabledNotifier.value) {
      _pulseController.repeat();
      _breathController.repeat(reverse: true);
      _particlesController.repeat();
    } else {
      _pulseController.stop();
      _breathController.stop();
      _particlesController.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    securityEnabledNotifier.addListener(_onSecurityEnabledChanged);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _particlesController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSecurityAnimations());
  }

  @override
  void dispose() {
    securityEnabledNotifier.removeListener(_onSecurityEnabledChanged);
    _pulseController.dispose();
    _breathController.dispose();
    _particlesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: securityEnabledNotifier,
      builder: (context, isEnabled, _) {
        if (!isEnabled) return _buildDisabledState(context);
        return StreamBuilder<SecurityStatus>(
          stream: _security.statusStream,
          initialData: _security.currentStatus,
          builder: (context, snapshot) {
            final status = snapshot.data ?? _security.currentStatus;
            return _buildTabBody(context, status);
          },
        );
      },
    );
  }

  /// Spazio sopra la bottom bar (extendBody + nav custom ~76pt + margine).
  static const double _bottomNavClearance = 88;

  Widget _buildDisabledState(BuildContext context) {
    final bottomPadding =
        MediaQuery.of(context).padding.bottom + 24 + _bottomNavClearance;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _MatrixLinesPainter(
              progress: 0,
              color: Colors.grey.withValues(alpha: 0.22),
            ),
          ),
        ),
        Positioned.fill(
          child: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, bottomPadding),
            children: [
              _buildDisabledStatusHero(),
              const SizedBox(height: 16),
              _buildDisabledScoreCard(),
              const SizedBox(height: 16),
              _buildChecksGridDisabled(context),
            ],
          ),
        ),
      ],
    );
  }

  /// Stesso layout dell’hero attivo: card bianca, bordo e testi in grigio; niente animazioni (controller fermi).
  Widget _buildDisabledStatusHero() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      decoration: _axCardDecoration(
        borderColor: Colors.grey.shade300,
        borderWidth: 1,
      ),
      child: Column(
        children: [
          SecurityShieldAnimatedLogo(
            pulseController: _pulseController,
            breathController: _breathController,
            size: _heroLogoSize,
            accentColor: Colors.grey.shade600,
          ),
          const SizedBox(height: 8),
          Text(
            'Monitoraggio disattivato',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade800,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Attiva Security nelle Impostazioni per i controlli in tempo reale',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.grey.shade400,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.power_settings_new_rounded,
                      size: 14,
                      color: Colors.grey.shade700,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Non in ascolto',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Scan: —',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Stessa struttura della score card attiva, palette grigia e barra vuota.
  Widget _buildDisabledScoreCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _axCardDecoration(
        borderColor: Colors.grey.shade200,
        borderWidth: 1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Threat Score',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                ),
              ),
              Text(
                '0/100',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 8,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Colors.grey.shade200),
                  FractionallySizedBox(
                    widthFactor: 0,
                    heightFactor: 1,
                    alignment: Alignment.centerLeft,
                    child: ColoredBox(color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _scoreLegendDisabled('0–24', 'Sicuro'),
              _scoreLegendDisabled('25–59', 'Attenzione'),
              _scoreLegendDisabled('60–100', 'Critico'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scoreLegendDisabled(String range, String label) {
    final dot = Colors.grey.shade400;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              range,
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
            ),
          ],
        ),
      ],
    );
  }

  /// Stessa griglia e metriche di [_buildChecksGrid], tile in stile attivo ma tutte grigie e stato "—".
  Widget _buildChecksGridDisabled(BuildContext context) {
    final checks = _securityCheckDefinitions();
    const crossSpacing = 10.0;
    const mainSpacing = 10.0;
    const aspectBase = 2.45;
    const rows = 5;
    const topPad = 16.0;
    const titleGap = 14.0;
    const titleH = 18.0;
    const gridExtraHeight = 80.0;
    const gridBottomPad = 12.0;
    const horizontalPad = 32.0;
    const layoutEpsilon = 6.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final innerW =
            (constraints.maxWidth - horizontalPad).clamp(1.0, double.infinity);
        final cellW = (innerW - crossSpacing) / 2;
        final rowHNatural = cellW / aspectBase;
        final gridHNatural = rows * rowHNatural + (rows - 1) * mainSpacing;
        final gridHFixed = gridHNatural + gridExtraHeight;
        final rowH = (gridHFixed - (rows - 1) * mainSpacing) / rows;
        final boxOuterH = topPad +
            titleH +
            titleGap +
            gridHFixed +
            gridBottomPad +
            layoutEpsilon;

        return SizedBox(
          height: boxOuterH,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, topPad, 16, 0),
            decoration: _axCardDecoration(
              borderColor: Colors.grey.shade200,
              borderWidth: 1,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: titleH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Controlli di Sicurezza',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: titleGap),
                SizedBox(
                  height: gridHFixed + gridBottomPad,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: gridHFixed,
                        child: GridView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: crossSpacing,
                            mainAxisSpacing: mainSpacing,
                            mainAxisExtent: rowH,
                          ),
                          children: checks
                              .map(
                                (c) => SizedBox.expand(
                                  child: _buildCheckTile(
                                    c.$1,
                                    c.$2,
                                    c.$3,
                                    false,
                                    uiDisabled: true,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                      const SizedBox(height: gridBottomPad),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<(ThreatType, IconData, String)> _securityCheckDefinitions() => [
        (ThreatType.appTampering, Icons.verified_user_outlined, 'Integrità App'),
        (ThreatType.jailbreakRoot, Icons.phonelink_lock_outlined, 'Jailbreak/Root'),
        (ThreatType.debuggerAttached, Icons.bug_report_outlined, 'Debugger'),
        (ThreatType.frideaHook, Icons.extension_outlined, 'Hook Framework'),
        (ThreatType.suspiciousNetwork, Icons.wifi_tethering_outlined, 'Rete'),
        (ThreatType.microphoneHijack, Icons.mic_none_outlined, 'Microfono'),
        (ThreatType.cameraHijack, Icons.camera_alt_outlined, 'Fotocamera'),
        (ThreatType.clipboardHijack, Icons.content_paste, 'Appunti'),
        (ThreatType.overlayAttack, Icons.layers_outlined, 'Overlay'),
        (ThreatType.accessibilityAbuse, Icons.accessibility_new_outlined, 'Accessibilità'),
      ];

  Widget _buildTabBody(BuildContext context, SecurityStatus status) {
    final bottomPadding =
        MediaQuery.of(context).padding.bottom + 24 + _bottomNavClearance;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildMatrixBackground(),
        Positioned.fill(
          child: _buildScrollableContent(
            context,
            status,
            bottomPadding,
            topPadding: 4,
          ),
        ),
      ],
    );
  }

  Widget _buildMatrixBackground() {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _particlesController,
        builder: (context, _) => CustomPaint(
          painter: _MatrixLinesPainter(
            progress: _particlesController.value,
            color: AppColors.primary.withValues(alpha: 0.08),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollableContent(
    BuildContext context,
    SecurityStatus status,
    double bottomPadding, {
    required double topPadding,
  }) {
    final config = _levelConfig(status.level);
    return ListView(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, bottomPadding),
      children: [
        _buildStatusHero(status, config),
        const SizedBox(height: 16),
        _buildScoreCard(status, config),
        const SizedBox(height: 16),
        _buildChecksGrid(status),
        if (status.events.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildEventsList(status),
        ],
      ],
    );
  }

  BoxDecoration _axCardDecoration({Color? borderColor, double borderWidth = 1}) {
    return BoxDecoration(
      color: Colors.white.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: borderColor ?? Colors.white.withValues(alpha: 0.6),
        width: borderWidth,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  // ─── HERO STATUS ──────────────────────────────

  Widget _buildStatusHero(SecurityStatus status, _LevelConfig config) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      decoration: _axCardDecoration(
        borderColor: AppColors.primary.withValues(alpha: 0.35),
        borderWidth: 1,
      ),
      child: Column(
        children: [
          SecurityShieldAnimatedLogo(
            pulseController: _pulseController,
            breathController: _breathController,
            size: _heroLogoSize,
            accentColor: AppColors.primary,
          ),
          const SizedBox(height: 8),
          Text(
            config.label,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: status.level == ThreatLevel.safe
                  ? AppColors.textPrimary
                  : config.accentColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            config.subtitle,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (status.isMonitoring) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Monitoraggio attivo',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                'Scan: ${_formatTime(status.lastCheck)}',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── SCORE CARD ───────────────────────────────

  Widget _buildScoreCard(SecurityStatus status, _LevelConfig config) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _axCardDecoration(
        borderColor: Colors.grey.shade200,
        borderWidth: 1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Threat Score',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              Text(
                '${status.totalScore}/100',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildThreatScoreBar(status),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _scoreLegend('0–24', AppColors.primary, 'Sicuro'),
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
            Text(range, style: TextStyle(fontSize: 9, color: Colors.grey[500])),
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

    final checks = _securityCheckDefinitions();

    const crossSpacing = 10.0;
    const mainSpacing = 10.0;
    const aspectBase = 2.45;
    const rows = 5;
    const topPad = 16.0;
    const titleGap = 14.0;
    const titleH = 18.0;
    /// Slack sotto la griglia “naturale” (2.45) ripartito sulle 5 righe.
    const gridExtraHeight = 80.0;
    const gridBottomPad = 12.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPad = 32.0; // padding sinistro+destro del Container
        final innerW =
            (constraints.maxWidth - horizontalPad).clamp(1.0, double.infinity);
        final cellW = (innerW - crossSpacing) / 2;
        final rowHNatural = cellW / aspectBase;
        final gridHNatural = rows * rowHNatural + (rows - 1) * mainSpacing;
        final gridHFixed = gridHNatural + gridExtraHeight;
        final rowH = (gridHFixed - (rows - 1) * mainSpacing) / rows;
        // Arrotondamenti della GridView / subpixel: evita overflow di pochi px sulla Column.
        const layoutEpsilon = 6.0;
        final boxOuterH = topPad +
            titleH +
            titleGap +
            gridHFixed +
            gridBottomPad +
            layoutEpsilon;

        return SizedBox(
          height: boxOuterH,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, topPad, 16, 0),
            decoration: _axCardDecoration(
              borderColor: Colors.grey.shade200,
              borderWidth: 1,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: titleH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Controlli di Sicurezza',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[600],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: titleGap),
                SizedBox(
                  height: gridHFixed + gridBottomPad,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: gridHFixed,
                        child: GridView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: crossSpacing,
                            mainAxisSpacing: mainSpacing,
                            mainAxisExtent: rowH,
                          ),
                          children: checks
                              .map((c) => SizedBox.expand(
                                    child: _buildCheckTile(
                                      c.$1,
                                      c.$2,
                                      c.$3,
                                      recentTypes.contains(c.$1),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ),
                      const SizedBox(height: gridBottomPad),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCheckTile(
    ThreatType _,
    IconData icon,
    String label,
    bool triggered, {
    bool uiDisabled = false,
  }) {
    if (uiDisabled) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final cellH =
              constraints.maxHeight.isFinite ? constraints.maxHeight : 44.0;
          var iconBox = (cellH * 0.44).clamp(24.0, 40.0);
          var padV = (cellH * 0.10).clamp(4.0, 10.0);
          if (2 * padV + iconBox > cellH) {
            padV = ((cellH - iconBox) / 2).clamp(2.0, 10.0);
          }
          if (2 * padV + iconBox > cellH) {
            iconBox = (cellH - 2 * padV - 2).clamp(20.0, 40.0);
          }
          final iconGlyph = (iconBox * 0.5).clamp(12.0, 18.0);
          const padH = 8.0;
          final titleSize = (cellH * 0.16).clamp(8.5, 11.0);
          final statusSize = (cellH * 0.13).clamp(7.5, 9.5);
          final borderGrey = Colors.grey.shade300;
          return Container(
            width: double.infinity,
            height: double.infinity,
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderGrey.withValues(alpha: 0.55)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: iconBox,
                  height: iconBox,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: iconGlyph, color: Colors.grey.shade600),
                ),
                SizedBox(width: (padH * 0.85).clamp(6.0, 10.0)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                          height: 1.15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '—',
                        style: TextStyle(
                          fontSize: statusSize,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey.shade500,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    final ok = !triggered;
    final color = ok ? AppColors.primary : AppColors.error;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellH = constraints.maxHeight.isFinite ? constraints.maxHeight : 44.0;
        var iconBox = (cellH * 0.44).clamp(24.0, 40.0);
        var padV = (cellH * 0.10).clamp(4.0, 10.0);
        if (2 * padV + iconBox > cellH) {
          padV = ((cellH - iconBox) / 2).clamp(2.0, 10.0);
        }
        if (2 * padV + iconBox > cellH) {
          iconBox = (cellH - 2 * padV - 2).clamp(20.0, 40.0);
        }
        final iconGlyph = (iconBox * 0.5).clamp(12.0, 18.0);
        const padH = 8.0;
        final titleSize = (cellH * 0.16).clamp(8.5, 11.0);
        final statusSize = (cellH * 0.13).clamp(7.5, 9.5);
        return Container(
          width: double.infinity,
          height: double.infinity,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.22)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: iconBox,
                height: iconBox,
                decoration: BoxDecoration(
                  color: AppColors.teal50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: iconGlyph, color: AppColors.primary),
              ),
              SizedBox(width: (padH * 0.85).clamp(6.0, 10.0)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.w600,
                        color: _navyHeader,
                        height: 1.15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      ok ? 'OK' : 'ALLERTA',
                      style: TextStyle(
                        fontSize: statusSize,
                        fontWeight: FontWeight.w700,
                        color: color,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─── EVENTS LIST ──────────────────────────────

  Widget _buildEventsList(SecurityStatus status) {
    final recent = status.events.reversed.take(20).toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _axCardDecoration(
        borderColor: Colors.grey.shade200,
        borderWidth: 1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Log Minacce',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
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
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
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
                        fontSize: 12, color: _navyHeader,
                        fontWeight: FontWeight.w500),
                    maxLines: 2),
                const SizedBox(height: 2),
                Text(_formatTime(event.timestamp),
                    style: TextStyle(
                        fontSize: 10, color: Colors.grey[500])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── HELPERS ──────────────────────────────────

  /// Barra score senza `LinearProgressIndicator` (il tema Material può alterare il verde).
  Widget _buildThreatScoreBar(SecurityStatus status) {
    final config = _levelConfig(status.level);
    final t = (status.totalScore / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 8,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppColors.divider),
            FractionallySizedBox(
              widthFactor: t,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: ColoredBox(color: config.accentColor),
            ),
          ],
        ),
      ),
    );
  }

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
          label: 'Dispositivo Sicuro',
          subtitle: 'Nessuna minaccia rilevata',
        );
      case ThreatLevel.warning:
        return const _LevelConfig(
          accentColor: AppColors.warning,
          label: 'Attenzione',
          subtitle: 'Attività sospetta rilevata',
        );
      case ThreatLevel.critical:
        return const _LevelConfig(
          accentColor: AppColors.error,
          label: 'Minaccia Critica',
          subtitle: 'Azioni di protezione attive',
        );
    }
  }
}

// ─── CONFIG LIVELLO ───────────────────────────

class _LevelConfig {
  final Color accentColor;
  final String label;
  final String subtitle;
  const _LevelConfig({
    required this.accentColor,
    required this.label,
    required this.subtitle,
  });
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
