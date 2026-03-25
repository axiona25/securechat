import 'dart:async';
import 'dart:math' as math;

/// Livello sintetico dello stato di sicurezza (derivato dallo score).
enum ThreatLevel {
  safe,
  warning,
  critical,
}

enum ThreatType {
  appTampering,
  jailbreakRoot,
  debuggerAttached,
  frideaHook,
  suspiciousNetwork,
  microphoneHijack,
  cameraHijack,
  clipboardHijack,
  overlayAttack,
  accessibilityAbuse,
}

class ThreatEvent {
  const ThreatEvent({
    required this.type,
    required this.score,
    required this.description,
    required this.timestamp,
  });

  final ThreatType type;
  final int score;
  final String description;
  final DateTime timestamp;
}

class SecurityStatus {
  const SecurityStatus({
    required this.level,
    required this.isMonitoring,
    required this.lastCheck,
    required this.totalScore,
    this.events = const [],
  });

  final ThreatLevel level;
  final bool isMonitoring;
  final DateTime lastCheck;
  final int totalScore;
  final List<ThreatEvent> events;

  static ThreatLevel levelForScore(int score) {
    final s = score.clamp(0, 100);
    if (s >= 60) return ThreatLevel.critical;
    if (s >= 25) return ThreatLevel.warning;
    return ThreatLevel.safe;
  }

  SecurityStatus copyWith({
    ThreatLevel? level,
    bool? isMonitoring,
    DateTime? lastCheck,
    int? totalScore,
    List<ThreatEvent>? events,
  }) {
    return SecurityStatus(
      level: level ?? this.level,
      isMonitoring: isMonitoring ?? this.isMonitoring,
      lastCheck: lastCheck ?? this.lastCheck,
      totalScore: totalScore ?? this.totalScore,
      events: events ?? this.events,
    );
  }
}

/// Servizio centralizzato per lo stato del security monitor (placeholder finché
/// non sono collegati check nativi / platform channel).
class SecurityService {
  SecurityService._() {
    _status = SecurityStatus(
      level: ThreatLevel.safe,
      isMonitoring: true,
      lastCheck: DateTime.now(),
      totalScore: 0,
      events: const [],
    );
    _emit();
    Timer.periodic(const Duration(seconds: 45), (_) {
      _status = _status.copyWith(lastCheck: DateTime.now());
      _emit();
    });
  }

  static final SecurityService _instance = SecurityService._();

  factory SecurityService() => _instance;

  final _controller = StreamController<SecurityStatus>.broadcast();
  late SecurityStatus _status;

  Stream<SecurityStatus> get statusStream => _controller.stream;

  SecurityStatus get currentStatus => _status;

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(_status);
    }
  }

  static int _computeScore(List<ThreatEvent> events) {
    if (events.isEmpty) return 0;
    var max = 0;
    for (final e in events) {
      if (e.score > max) max = e.score;
    }
    return math.min(100, max);
  }

  /// Registra un evento (es. da codice nativo). Aggiorna score e livello.
  void recordThreat({
    required ThreatType type,
    required int score,
    required String description,
    DateTime? at,
  }) {
    final event = ThreatEvent(
      type: type,
      score: score.clamp(0, 100),
      description: description,
      timestamp: at ?? DateTime.now(),
    );
    final nextEvents = List<ThreatEvent>.from(_status.events)..add(event);
    final total = _computeScore(nextEvents);
    _status = SecurityStatus(
      level: SecurityStatus.levelForScore(total),
      isMonitoring: _status.isMonitoring,
      lastCheck: DateTime.now(),
      totalScore: total,
      events: nextEvents,
    );
    _emit();
  }

  /// Ripristina stato “sicuro” (es. dopo logout o reset test).
  void clearEvents() {
    _status = SecurityStatus(
      level: ThreatLevel.safe,
      isMonitoring: _status.isMonitoring,
      lastCheck: DateTime.now(),
      totalScore: 0,
      events: const [],
    );
    _emit();
  }
}
