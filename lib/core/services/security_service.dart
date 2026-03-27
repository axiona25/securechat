// lib/core/services/security_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum ThreatLevel { safe, warning, critical }

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

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'score': score,
    'description': description,
    'timestamp': timestamp.toIso8601String(),
  };
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
  }) => SecurityStatus(
    level: level ?? this.level,
    isMonitoring: isMonitoring ?? this.isMonitoring,
    lastCheck: lastCheck ?? this.lastCheck,
    totalScore: totalScore ?? this.totalScore,
    events: events ?? this.events,
  );
}

class SecurityService {
  SecurityService._() {
    _status = SecurityStatus(
      level: ThreatLevel.safe,
      isMonitoring: false,
      lastCheck: DateTime.now(),
      totalScore: 0,
      events: const [],
    );
  }

  static final SecurityService _instance = SecurityService._();
  factory SecurityService() => _instance;

  static const _channel = MethodChannel('com.axphone.app/security');
  static const _scanInterval = Duration(seconds: 30);
  static const _baseUrl = 'https://axphone.it/api/security';

  Future<void> Function()? onForcedLogout;
  void Function(String message)? onThreatAlert;
  void Function(bool blocked)? onMessagingBlocked;

  final _controller = StreamController<SecurityStatus>.broadcast();
  late SecurityStatus _status;
  Timer? _timer;
  bool _actionsBlocked = false;
  Timer? _forcedLogoutTimer;
  final Map<ThreatType, DateTime> _lastEventTime = {};
  String? _knownBinaryHash;

  Stream<SecurityStatus> get statusStream => _controller.stream;
  SecurityStatus get currentStatus => _status;

  Future<void> startMonitoring() async {
    if (_status.isMonitoring) return;
    _status = _status.copyWith(isMonitoring: true, lastCheck: DateTime.now());
    _emit();

    // Hash iniziale del binario (baseline per tampering check)
    try {
      _knownBinaryHash = await _channel.invokeMethod<String>('getBinaryHash');
    } catch (_) {}

    // Scan immediato all'avvio
    await _runScan();

    // Timer ogni 30 secondi
    _timer = Timer.periodic(_scanInterval, (_) => _runScan());
  }

  void stopMonitoring() {
    _forcedLogoutTimer?.cancel();
    _forcedLogoutTimer = null;
    _timer?.cancel();
    _timer = null;
    _knownBinaryHash = null;
    _actionsBlocked = false;
    onMessagingBlocked?.call(false);
    _status = SecurityStatus(
      level: ThreatLevel.safe,
      isMonitoring: false,
      lastCheck: DateTime.now(),
      totalScore: 0,
      events: const [],
    );
    _lastEventTime.clear();
    _emit();
  }

  void clearEvents() {
    _actionsBlocked = false;
    _status = SecurityStatus(
      level: ThreatLevel.safe,
      isMonitoring: _status.isMonitoring,
      lastCheck: DateTime.now(),
      totalScore: 0,
      events: const [],
    );
    _lastEventTime.clear();
    _emit();
  }

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
    _addEvents([event]);
  }

  // ─── SCAN PRINCIPALE ────────────────────────────────────────

  Future<void> _runScan() async {
    final newEvents = <ThreatEvent>[];

    await Future.wait([
      _checkJailbreak().then((e) { if (e != null) newEvents.add(e); }),
      _checkDebugger().then((e) { if (e != null) newEvents.add(e); }),
      _checkTampering().then((e) { if (e != null) newEvents.add(e); }),
      _checkHooks().then((e) { if (e != null) newEvents.add(e); }),
      _checkNetwork().then((e) { if (e != null) newEvents.add(e); }),
      _checkClipboard().then((e) { if (e != null) newEvents.add(e); }),
    ]);

    final accepted = _addEvents(newEvents);

    if (accepted.isNotEmpty) {
      _reportToBackend(accepted);
    }
  }

  List<ThreatEvent> _addEvents(List<ThreatEvent> newEvents) {
    if (newEvents.isEmpty) {
      final cutoffEmpty = DateTime.now()
          .subtract(const Duration(minutes: 5));
      final recentEmpty = _status.events
          .where((e) => !e.timestamp.isBefore(cutoffEmpty))
          .toList();
      final totalEmpty = recentEmpty.isEmpty
          ? 0
          : math.min(
              100,
              recentEmpty.fold<int>(0, (sum, e) => sum + e.score),
            );
      final levelEmpty = SecurityStatus.levelForScore(totalEmpty);
      _status = SecurityStatus(
        level: levelEmpty,
        isMonitoring: _status.isMonitoring,
        lastCheck: DateTime.now(),
        totalScore: totalEmpty,
        events: _status.events,
      );
      _emit();
      _handleLevelDown(levelEmpty);
      return [];
    }

    // Debounce: ignora eventi dello stesso tipo
    // se già registrato negli ultimi 5 minuti
    final now = DateTime.now();
    final deduped = newEvents.where((e) {
      final last = _lastEventTime[e.type];
      if (last != null &&
          now.difference(last) <= const Duration(minutes: 5)) {
        return false;
      }
      return true;
    }).toList();

    if (deduped.isEmpty) {
      // Nessun nuovo evento accettato, ma ricalcola
      // score/livello rispetto al tempo corrente:
      // eventi vecchi potrebbero essere usciti dalla finestra.
      final cutoffNow = now.subtract(const Duration(minutes: 5));
      final recentNow = _status.events
          .where((e) => !e.timestamp.isBefore(cutoffNow))
          .toList();
      final totalNow = recentNow.isEmpty
          ? 0
          : math.min(
              100,
              recentNow.fold<int>(0, (sum, e) => sum + e.score),
            );
      final levelNow = SecurityStatus.levelForScore(totalNow);
      _status = SecurityStatus(
        level: levelNow,
        isMonitoring: _status.isMonitoring,
        lastCheck: now,
        totalScore: totalNow,
        events: _status.events,
      );
      _emit();
      _handleLevelDown(levelNow);
      return [];
    }

    // Aggiorna timestamp per i tipi che passano il filtro
    for (final e in deduped) {
      _lastEventTime[e.type] = now;
    }

    final all = List<ThreatEvent>.from(_status.events)..addAll(deduped);
    // Mantieni ultimi 100 eventi
    final trimmed = all.length > 100 ? all.sublist(all.length - 100) : all;

    // Score: considera eventi ultimi 5 minuti
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    final recent = trimmed
        .where((e) => !e.timestamp.isBefore(cutoff))
        .toList();
    final total = recent.isEmpty ? 0 : math.min(
      100,
      recent.fold<int>(0, (sum, e) => sum + e.score),
    );

    final level = SecurityStatus.levelForScore(total);
    _status = SecurityStatus(
      level: level,
      isMonitoring: _status.isMonitoring,
      lastCheck: DateTime.now(),
      totalScore: total,
      events: trimmed,
    );
    _emit();
    _handleLevel(level, deduped);
    return deduped;
  }

  // ─── CHECK INDIVIDUALI ───────────────────────────────────────

  Future<ThreatEvent?> _checkJailbreak() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'checkJailbreakRoot',
      );
      if (result == null) return null;
      final detected = result['detected'] == true;
      if (!detected) return null;
      final vector = result['vector']?.toString() ?? 'unknown';
      final detail = result['detail']?.toString() ?? '';
      final severity = result['severity']?.toString() ?? 'high';
      debugPrint('[Security] Jailbreak: vector=$vector detail=$detail');
      return ThreatEvent(
        type: ThreatType.jailbreakRoot,
        score: severity == 'high' ? 70 : 40,
        description: 'Jailbreak rilevato — $vector'
            '${detail.isNotEmpty ? ": $detail" : ""}',
        timestamp: DateTime.now(),
      );
    } catch (e) {
      debugPrint('[Security] checkJailbreak error: $e');
    }
    return null;
  }

  Future<ThreatEvent?> _checkDebugger() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'checkDebuggerAttached',
      );
      if (result == null) return null;
      final detected = result['detected'] == true;
      if (!detected) return null;
      final detail = result['detail']?.toString() ?? '';
      final pid = result['pid']?.toString() ?? '';
      final pFlag = result['p_flag']?.toString() ?? '';
      debugPrint('[Security] Debugger: detail=$detail '
          'pid=$pid p_flag=$pFlag');
      return ThreatEvent(
        type: ThreatType.debuggerAttached,
        score: 80,
        description: 'Debugger collegato — $detail'
            '${pid.isNotEmpty ? " (PID $pid)" : ""}',
        timestamp: DateTime.now(),
      );
    } catch (e) {
      debugPrint('[Security] checkDebugger error: $e');
    }
    return null;
  }

  Future<ThreatEvent?> _checkTampering() async {
    try {
      // Usa getBinaryHashDetailed passando la baseline
      final result = await _channel.invokeMethod<Map>(
        'getBinaryHashDetailed',
        _knownBinaryHash,
      );
      if (result == null) return null;

      final currentHash =
          result['currentHash']?.toString() ?? 'unknown';
      final detail =
          result['detail']?.toString() ?? '';
      final execSize = result['executableSize'] ?? 0;

      // Aggiorna baseline se non impostata
      if (_knownBinaryHash == null
          || _knownBinaryHash == 'unknown') {
        _knownBinaryHash = currentHash;
        final prefix = currentHash.length >= 16
            ? currentHash.substring(0, 16)
            : currentHash;
        debugPrint('[Security] Tampering baseline: '
            '$prefix... '
            'size=${execSize}b');
        return null;
      }

      final tampered = result['detected'] == true;
      debugPrint('[Security] Tampering: tampered=$tampered '
          'detail=$detail size=${execSize}b');

      if (tampered) {
        return ThreatEvent(
          type: ThreatType.appTampering,
          score: 90,
          description: 'Binario modificato — $detail',
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint('[Security] checkTampering error: $e');
    }
    return null;
  }

  Future<ThreatEvent?> _checkHooks() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'checkHookFrameworks',
      );
      if (result == null) return null;
      final detected = result['detected'] == true;
      if (!detected) return null;
      final vector =
          result['vector']?.toString() ?? 'unknown';
      final framework =
          result['framework']?.toString() ?? 'unknown';
      final detail =
          result['detail']?.toString() ?? '';
      debugPrint('[Security] Hook: vector=$vector '
          'framework=$framework detail=$detail');
      return ThreatEvent(
        type: ThreatType.frideaHook,
        score: 85,
        description: 'Hook framework rilevato — '
            '$framework ($vector)'
            '${detail.isNotEmpty ? ": $detail" : ""}',
        timestamp: DateTime.now(),
      );
    } catch (e) {
      debugPrint('[Security] checkHooks error: $e');
    }
    return null;
  }

  Future<ThreatEvent?> _checkNetwork() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'checkNetworkAnomalies',
      );
      if (result == null) return null;
      final detected = result['detected'] == true;
      if (!detected) return null;

      final proxyDetected =
          result['proxy_detected'] == true;
      final proxyHost =
          result['proxy_host']?.toString() ?? '';
      final proxyPort =
          result['proxy_port']?.toString() ?? '';
      final vpnActive =
          result['vpn_active'] == true;
      final vpnInterfaces =
          (result['vpn_interfaces'] as List?)
              ?.map((e) => e.toString()).toList() ?? [];
      final vector =
          result['vector']?.toString() ?? 'unknown';
      final severity =
          result['severity']?.toString() ?? 'medium';

      debugPrint('[Security] Network: proxy=$proxyDetected '
          'host=$proxyHost:$proxyPort '
          'vpn=$vpnActive interfaces=$vpnInterfaces '
          'vector=$vector severity=$severity');

      if (proxyDetected) {
        return ThreatEvent(
          type: ThreatType.suspiciousNetwork,
          score: 40,
          description: 'Proxy di rete rilevato: '
              '$proxyHost'
              '${proxyPort.isNotEmpty ? ":$proxyPort" : ""}',
          timestamp: DateTime.now(),
        );
      }
      if (vpnActive) {
        final ifaceStr = vpnInterfaces.take(3).join(', ');
        return ThreatEvent(
          type: ThreatType.suspiciousNetwork,
          score: 20,
          description: 'VPN non trusted attiva — '
              'interfacce: $ifaceStr',
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint('[Security] checkNetwork error: $e');
    }
    return null;
  }

  Future<ThreatEvent?> _checkClipboard() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'checkClipboardHijack',
      );
      if (result == null) return null;

      final reason =
          result['reason']?.toString() ?? '';
      final hijack = result['hijack'] == true;
      final appState =
          result['appState']?.toString() ?? '';
      final delta = result['delta'] ?? 0;
      final contentType =
          result['contentType']?.toString() ?? '';
      final preview =
          result['contentPreview']?.toString() ?? '';
      final changeCount =
          result['changeCount'] ?? 0;

      debugPrint('[Clipboard] reason=$reason '
          'appState=$appState delta=$delta '
          'type=$contentType count=$changeCount');
      if (preview.isNotEmpty) {
        debugPrint('[Clipboard] preview="$preview"');
      }

      if (hijack) {
        return ThreatEvent(
          type: ThreatType.clipboardHijack,
          score: 50,
          description: 'Appunti modificati in background'
              ' (delta=+$delta, tipo=$contentType'
              '${preview.isNotEmpty
                  ? ", anteprima: ${preview.length > 40
                      ? "${preview.substring(0, 40)}..."
                      : preview}"
                  : ""})',
          timestamp: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint('[Security] checkClipboard error: $e');
    }
    return null;
  }

  // ─── AZIONI AUTOMATICHE ──────────────────────────────────────

  void _handleLevel(ThreatLevel level, List<ThreatEvent> newEvents) {
    if (newEvents.isNotEmpty) {
      final worst = newEvents.reduce((a, b) => a.score >= b.score ? a : b);
      onThreatAlert?.call('⚠️ ${worst.description}');
    }

    if (level == ThreatLevel.critical && !_actionsBlocked) {
      _actionsBlocked = true;
      onMessagingBlocked?.call(true);
      _forcedLogoutTimer?.cancel();
      _forcedLogoutTimer = Timer(const Duration(seconds: 3), () {
        onForcedLogout?.call();
      });
    }
  }

  // Chiamato quando il livello scende da critical a safe/warning.
  // Azzera flag e callback senza generare nuovi alert.
  void _handleLevelDown(ThreatLevel newLevel) {
    if (newLevel != ThreatLevel.critical && _actionsBlocked) {
      _actionsBlocked = false;
      _forcedLogoutTimer?.cancel();
      _forcedLogoutTimer = null;
      onMessagingBlocked?.call(false);
      debugPrint('[Security] Livello sceso a ${newLevel.name} — messaging sbloccato');
    }
  }

  // ─── REPORT BACKEND ──────────────────────────────────────────

  Future<void> _reportToBackend(List<ThreatEvent> events) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');
      if (token == null) return;

      final payload = jsonEncode({
        'events': events.map((e) => e.toJson()).toList(),
        'total_score': _status.totalScore,
        'level': _status.level.name,
        'platform': 'ios',
      });

      await http.post(
        Uri.parse('$_baseUrl/report/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: payload,
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[Security] report to backend failed: $e');
    }
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(_status);
  }
}
