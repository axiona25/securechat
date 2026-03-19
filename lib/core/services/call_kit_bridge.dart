import 'dart:collection';

import '../utils/call_id_utils.dart';
import 'api_service.dart';

/// In-memory per-[callId] state for native CallKit accept / Flutter navigation.
/// Dart isolate is single-threaded; map updates are synchronous and safe for normal Flutter use.
class CallKitBridge {
  CallKitBridge._();
  static final CallKitBridge instance = CallKitBridge._();

  final Map<String, _CallKitEntry> _entries = HashMap();

  /// iOS: primo handler Dart per ACTION_CALL_ACCEPT per questo callId; i duplicati vanno ignorati.
  /// (Il plugin può reinviare accept dopo `setCallConnected` → secondo CXAnswerCallAction.)
  final Set<String> _iosCallKitAcceptDartHandledIds = {};

  /// `CallScreen` attualmente in stack per questo [callId] (1 chiamata alla volta).
  String? _flutterCallUiCallId;

  /// `true` se è il primo accept Dart da gestire per [callId], `false` se duplicato da ignorare.
  bool beginIosCallKitAcceptDartHandling(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return true;
    if (_iosCallKitAcceptDartHandledIds.contains(id)) return false;
    _iosCallKitAcceptDartHandledIds.add(id);
    return true;
  }

  void markAnswered(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return;
    _entries[id] = (_entries[id] ?? _CallKitEntry()).copyWith(
      answered: true,
      answeredAt: DateTime.now(),
    );
    _log('answered=true callId=$id');
    ApiService().postLog('[REMOTE-DEBUG] [CallKitBridge] answered=true callId=$id');
  }

  bool wasAnswered(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return false;
    return _entries[id]?.answered ?? false;
  }

  void markNavigated(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return;
    _entries[id] = (_entries[id] ?? _CallKitEntry()).copyWith(
      navigated: true,
      navigatedAt: DateTime.now(),
    );
    _log('navigated=true callId=$id');
    ApiService().postLog('[REMOTE-DEBUG] [CallKitBridge] navigated=true callId=$id');
  }

  bool wasNavigated(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return false;
    return _entries[id]?.navigated ?? false;
  }

  /// Chiamata mostrata da CallKit (PushKit path). Usato per stato per-callId, non flag globale.
  void markPresented(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return;
    _entries[id] = (_entries[id] ?? _CallKitEntry()).copyWith(
      presented: true,
      presentedAt: DateTime.now(),
    );
    _log('presented=true callId=$id');
    ApiService().postLog('[REMOTE-DEBUG] [CallKitBridge] presented=true callId=$id');
  }

  bool wasPresented(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return false;
    return _entries[id]?.presented ?? false;
  }

  void clear(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return;
    _entries.remove(id);
    _iosCallKitAcceptDartHandledIds.remove(id);
    if (_flutterCallUiCallId == id) {
      _flutterCallUiCallId = null;
    }
    _log('cleared callId=$id');
    ApiService().postLog('[REMOTE-DEBUG] [CallKitBridge] cleared callId=$id');
  }

  /// Registra che la UI Flutter della chiamata è montata (vedi [CallScreen]).
  void registerFlutterCallUi(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return;
    _flutterCallUiCallId = id;
    ApiService().postLog('[REMOTE-DEBUG] [CallKitBridge] registerFlutterCallUi callId=$id');
  }

  void unregisterFlutterCallUi(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return;
    if (_flutterCallUiCallId == id) {
      _flutterCallUiCallId = null;
      ApiService().postLog('[REMOTE-DEBUG] [CallKitBridge] unregisterFlutterCallUi callId=$id');
    }
  }

  bool isFlutterCallUiActiveFor(String callId) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return false;
    return _flutterCallUiCallId == id;
  }

  /// Guardia condivisa anti-doppia navigazione.
  /// - [includeNativeAnswered]=true: per abort del push schedulato da Home (CallKit ha già accettato).
  /// - false: per Voip prima del push (non bloccare il primo push solo perché answered).
  bool isCallUiHandledFor(String callId, {required bool includeNativeAnswered}) {
    final id = normalizeCallId(callId);
    if (id.isEmpty) return false;
    if (isFlutterCallUiActiveFor(id) || wasNavigated(id)) return true;
    if (includeNativeAnswered && wasAnswered(id)) return true;
    // CallKit già mostrato (PushKit / nativo): non aprire ringing Flutter in parallelo.
    if (includeNativeAnswered && wasPresented(id)) return true;
    return false;
  }

  void _log(String msg) {
    // ignore: avoid_print
    print('[REMOTE-DEBUG] [CallKitBridge] $msg');
  }
}

class _CallKitEntry {
  _CallKitEntry({
    this.answered = false,
    this.navigated = false,
    this.presented = false,
    this.answeredAt,
    this.navigatedAt,
    this.presentedAt,
  });

  final bool answered;
  final bool navigated;
  final bool presented;
  final DateTime? answeredAt;
  final DateTime? navigatedAt;
  final DateTime? presentedAt;

  _CallKitEntry copyWith({
    bool? answered,
    bool? navigated,
    bool? presented,
    DateTime? answeredAt,
    DateTime? navigatedAt,
    DateTime? presentedAt,
  }) {
    return _CallKitEntry(
      answered: answered ?? this.answered,
      navigated: navigated ?? this.navigated,
      presented: presented ?? this.presented,
      answeredAt: answeredAt ?? this.answeredAt,
      navigatedAt: navigatedAt ?? this.navigatedAt,
      presentedAt: presentedAt ?? this.presentedAt,
    );
  }
}
