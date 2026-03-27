import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../utils/call_id_utils.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'call_kit_bridge.dart';
import 'call_service.dart';
import 'securechat_notify_service.dart';
import 'conversation_cache_service.dart';
import '../../features/calls/screens/call_screen.dart';
import '../../main.dart';

/// Handles VoIP push (iOS PushKit) and CallKit incoming call UI.
/// Listens to native MethodChannel for token and incoming call payloads.
class VoipService {
  VoipService._();
  static final instance = VoipService._();

  static const _channel = MethodChannel('com.axphone.app/voip');

  /// Chiamata pendente da aprire quando il navigator è pronto
  static Map<String, dynamic>? _pendingAcceptedCall;

  static Map<String, dynamic>? getPendingAcceptedCall() {
    final call = _pendingAcceptedCall;
    _pendingAcceptedCall = null;
    return call;
  }

  /// True solo dopo che l'utente ha accettato da CallKit (`_onAccept`), non quando mostriamo l'UI incoming.
  /// Per resume/polling in HomeScreen; lo stato per-[callId] resta su [CallKitBridge].
  static bool _callKitAnswered = false;

  /// True dopo [FlutterCallkitIncoming.showCallkitIncoming] (PushKit path), finché non accetta/declina.
  /// Usato in Home per evitare UI Flutter ringing duplicata mentre manca ancora `call_id` dal WS.
  static bool _callKitIncomingPresented = false;

  static bool getAndClearCallKitAnswered() {
    final val = _callKitAnswered;
    _callKitAnswered = false;
    return val;
  }

  static bool isCallKitAnswered() => _callKitAnswered;
  static void clearCallKitAnswered() => _callKitAnswered = false;

  static bool isCallKitIncomingPresented() => _callKitIncomingPresented;
  static void clearCallKitIncomingPresented() => _callKitIncomingPresented = false;

  static bool _callKitNavigated = false;
  static void setCallKitNavigated() => _callKitNavigated = true;
  static bool getAndClearCallKitNavigated() {
    final val = _callKitNavigated;
    _callKitNavigated = false;
    return val;
  }

  /// Evita doppio handling se CallKit invia più eventi accept ravvicinati.
  static final Set<String> _nativeAcceptInFlight = {};

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService] init skipped: FlutterCallkitIncoming.onEvent already registered',
      );
      return;
    }
    _channel.setMethodCallHandler(_onMethodCall);
    await ApiService().postLog(
      '[REMOTE-DEBUG] [VoipService] registering FlutterCallkitIncoming.onEvent listener',
    );
    debugPrint('[REMOTE-DEBUG] [VoipService] registering FlutterCallkitIncoming.onEvent listener');
    FlutterCallkitIncoming.onEvent.listen(
      (event) {
        ApiService().postLog(
          '[REMOTE-DEBUG] [CallKitEvent.listen] raw event=$event',
        );
        if (event == null) {
          ApiService().postLog(
            '[REMOTE-DEBUG] [CallKitEvent.listen] eventName= body=null (null event)',
          );
          _onCallKitEvent(event);
          return;
        }
        final en = event.event.toString();
        final bd = event.body;
        ApiService().postLog(
          '[REMOTE-DEBUG] [CallKitEvent.listen] eventName=$en body=$bd',
        );
        _onCallKitEvent(event);
      },
      onError: (Object error, StackTrace stack) {
        ApiService().postLog(
          '[REMOTE-DEBUG] [CallKitEvent.listen] onError error=$error stack=$stack',
        );
      },
      onDone: () {
        ApiService().postLog(
          '[REMOTE-DEBUG] [CallKitEvent.listen] onDone stream closed',
        );
      },
      cancelOnError: false,
    );
    _initialized = true;
    await ApiService().postLog('[REMOTE-DEBUG] [VoipService.init] initialized, onEvent listener active');
    _log('[VoipService.init] initialized');
  }

  Future<void> retryVoipTokenRegistration() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('voip_token_pending');
    if (token != null && token.isNotEmpty) {
      await _sendVoipTokenToBackend(token);
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'voipTokenReceived':
        final token = call.arguments as String?;
        if (token != null && token.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('voip_token_pending', token);
          await _sendVoipTokenToBackend(token);
        }
        return null;
      case 'remoteLog':
        final msg = call.arguments is String ? call.arguments as String : call.arguments?.toString() ?? '';
        if (msg.isNotEmpty) ApiService().postLog(msg);
        return null;
      case 'incomingCall':
        final args = call.arguments;
        if (args is Map) {
          final handle = args['handle'] as String? ?? '';
          final callerName = args['callerName'] as String? ?? handle;
          final callId = normalizeCallId(args['callId'] as String?);
          final callType = args['callType'] as String? ?? 'audio';
          final callerUserId = args['callerUserId'] as String? ?? '';
          final conversationId = args['conversationId'] as String? ?? '';
          final nativeAlreadyShown = args['nativeCallKitShown'] == true;
          if (callId.isEmpty) {
            await ApiService().postLog('[VoipService.incomingCall] abort empty callId after normalize');
            return null;
          }
          await ApiService().postLog(
            '[VoipService.incomingCall] received callId=$callId callerName=$callerName nativeCallKitShown=$nativeAlreadyShown',
          );
          // Salva dati chiamata per recupero in cold start
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pending_call_data', jsonEncode({
            'callId': callId,
            'callType': callType,
            'callerUserId': callerUserId,
            'conversationId': conversationId,
            'callerName': callerName,
            'handle': handle,
          }));
          // Se app in foreground, non mostrare CallKit — gestita via WebSocket
          final lifecycle = WidgetsBinding.instance.lifecycleState;
          if (lifecycle == AppLifecycleState.resumed) {
            await ApiService().postLog('[VoipService] app in foreground, skip CallKit');
            return null;
          }
          if (nativeAlreadyShown) {
            CallKitBridge.instance.markPresented(callId);
            _callKitIncomingPresented = true;
            await ApiService().postLog(
              '[VoipService.incomingCall] skip Dart showCallkitIncoming (AppDelegate PushKit already reported) callId=$callId',
            );
            return null;
          }
          await _showCallKitIncoming(
            callId: callId,
            callerName: callerName,
            handle: handle,
            callType: callType,
            callerUserId: callerUserId,
            conversationId: conversationId,
          );
          CallKitBridge.instance.markPresented(callId);
          _callKitIncomingPresented = true;
          await ApiService().postLog(
            '[VoipService.incomingCall] markPresented(callId) + legacy flag (Dart showCallkitIncoming)',
          );
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> _sendVoipTokenToBackend(String token) async {
    try {
      final accessToken = ApiService().accessToken;
      if (accessToken == null) return;

      // 1. Backend Django — mapping utente/token
      await http.post(
        Uri.parse('${AppConstants.baseUrl}/auth/voip-token/'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'voip_token': token}),
      );
      debugPrint('[VoipService] VoIP token inviato al backend Django');

      // 2. Notify server — necessario per inviare VoIP push
      final deviceToken = SecureChatNotifyService().deviceToken;
      final userId = await AuthService.getCurrentUserId();
      if (deviceToken != null && userId != null) {
        await http.post(
          Uri.parse('${AppConstants.notifyBaseUrl}/voip-token'),
          headers: {
            'Content-Type': 'application/json',
            'X-Notify-Service-Key': AppConstants.notifyServiceKey,
          },
          body: jsonEncode({
            'user_id': userId.toString(),
            'device_token': deviceToken,
            'voip_token': token,
          }),
        );
        debugPrint('[VoipService] VoIP token inviato al notify server');
      }
    } catch (e) {
      debugPrint('[VoipService] VoIP token registration error: $e');
    }
  }

  Future<void> _showCallKitIncoming({
    required String callId,
    required String callerName,
    required String handle,
    required String callType,
    required String callerUserId,
    required String conversationId,
  }) async {
    final type = callType == 'video' ? 1 : 0;
    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      handle: handle,
      type: type,
      appName: 'AXPHONE',
      avatar: 'assets/images/icona.png',
      textAccept: 'Accetta',
      textDecline: 'Rifiuta',
      duration: 45000,
      // Plugin default: configureAudioSession=true + mode default → AVAudioSession tweaks at
      // CXAnswerCallAction (before didActivate) conflittano con RTCAudioSession.useManualAudio.
      ios: const IOSParams(
        iconName: 'CallKitLogo',
        configureAudioSession: false,
        audioSessionActive: false,
      ),
      headers: <String, dynamic>{
        'callerUserId': callerUserId,
        'callId': callId,
        'conversationId': conversationId,
        'callType': callType,
      },
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  void _log(String msg) => ApiService().postLog(msg);

  /// Estrae callId da body (Map da EventChannel o oggetto con proprietà).
  /// Plugin invia body come Map; non usare .id/.uuid per evitare NoSuchMethodError.
  static String _extractCallIdFromBody(dynamic body) {
    if (body == null) return '';
    if (body is Map) {
      final id = body['id'] ?? body['uuid'];
      if (id != null) return normalizeCallId(id.toString());
      final extra = body['extra'];
      if (extra is Map) {
        final c = extra['callId'];
        if (c != null) return normalizeCallId(c.toString());
      }
      return '';
    }
    // Fallback se il plugin inviasse un oggetto con getter (es. CallKitCallEvent body)
    try {
      final id = (body as dynamic).id ?? (body as dynamic).uuid;
      if (id != null) return normalizeCallId(id.toString());
    } catch (_) {}
    return '';
  }

  void _onCallKitEvent(dynamic event) {
    ApiService().postLog(
      '[REMOTE-DEBUG] [VoipService._onCallKitEvent] event=${event?.event} body=${event?.body} raw=$event',
    );
    if (event == null) {
      ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onCallKitEvent] abort: null event',
      );
      return;
    }
    final eventName = event.event?.toString() ?? '';
    final body = event.body;

    if (body != null && body is! Map) {
      ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onCallKitEvent] body is not Map (type=${body.runtimeType}), treating as opaque',
      );
    }

    final bid = _extractCallIdFromBody(body);
    ApiService().postLog(
      '[REMOTE-DEBUG] [VoipService._onCallKitEvent] event=$eventName extracted callId=$bid body=${body is Map ? body : body?.toString()}',
    );
    _log('[VoipService._onCallKitEvent] RAW event=$eventName callId=$bid');

    if (eventName.contains('Accept') || eventName.contains('accept')) {
      if (bid.isEmpty) {
        ApiService().postLog(
          '[REMOTE-DEBUG] [VoipService._onCallKitEvent] ACCEPT event but no callId — ignoring (invalid payload)',
        );
        return;
      }
      ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onCallKitEvent] ACCEPT recognized callId=$bid event=$eventName',
      );
      _onAccept(body, eventName: eventName);
    } else if (eventName.contains('Decline') || eventName.contains('decline')) {
      _onDecline(body);
    } else if (eventName.contains('Incoming') || eventName.contains('incoming')) {
      ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onCallKitEvent] actionCallIncoming acknowledged callId=$bid (native CallKit handling)',
      );
    } else {
      ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onCallKitEvent] no callId for event=$eventName, handling non-call-specific event (e.g. ACTION_CALL_TOGGLE_AUDIO_SESSION)',
      );
    }
  }

  void _onAccept(dynamic body, {required String eventName}) async {
    await ApiService().postLog(
      '[REMOTE-DEBUG] [VoipService._onAccept] entry body=$body event=$eventName',
    );
    if (body == null) {
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onAccept] abort: null body event=$eventName',
      );
      return;
    }
    final callId = _extractCallIdFromBody(body);
    await ApiService().postLog(
      '[REMOTE-DEBUG] [VoipService._onAccept] extracted callId=$callId (normalized)',
    );
    if (callId.isEmpty) {
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onAccept] abort: empty callId body=$body',
      );
      return;
    }

    if (CallKitBridge.instance.wasNavigated(callId)) {
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onAccept] duplicate accept ignored callId=$callId (already navigated)',
      );
      return;
    }
    if (!_nativeAcceptInFlight.add(callId)) {
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onAccept] duplicate accept ignored callId=$callId (in flight)',
      );
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      if (!CallKitBridge.instance.beginIosCallKitAcceptDartHandling(callId)) {
        _nativeAcceptInFlight.remove(callId);
        await ApiService().postLog(
          '[CallKit-iOS] duplicate ACTION_CALL_ACCEPT ignored callId=$callId (per-callId dedupe; no second WS/nav/CallKit)',
        );
        return;
      }
      await ApiService().postLog(
        '[CallKit-iOS] first ACTION_CALL_ACCEPT accepted for Dart handling callId=$callId',
      );
    }

    final navEarly = navigatorKey.currentState;
    if (navEarly == null &&
        normalizeCallId(_pendingAcceptedCall?['callId']?.toString()) == callId) {
      _nativeAcceptInFlight.remove(callId);
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onAccept] duplicate accept ignored callId=$callId (cold pending already set)',
      );
      return;
    }

    try {
      _callKitAnswered = true;
      _callKitIncomingPresented = false;
      await ApiService().postLog(
        '[REMOTE-DEBUG] [VoipService._onAccept] callKitAnswered=true (user accepted), callKitIncomingPresented=false',
      );

      CallKitBridge.instance.markAnswered(callId);

      await ApiService().postLog(
        '[VoipService._onAccept] callId=$callId nav=${navEarly != null} event=$eventName',
      );

      final resolved = await _resolveIncomingContext(callId, body);
      final callerUserId = resolved['callerUserId'] as int? ?? 0;
      final conversationId = resolved['conversationId'] as String? ?? '';
      final callType = resolved['callType'] as String? ?? 'audio';
      final callerName = resolved['callerName'] as String? ?? '';

      if (callerUserId == 0) {
        await ApiService().postLog(
          '[REMOTE-DEBUG] [VoipService._onAccept] WARNING callerUserId still 0 after body+extra+prefs merge callId=$callId',
        );
      }

      String? avatarUrl = ConversationCacheService.instance.getAvatarForUser(callerUserId);

      // NON chiamare endCall qui: la sessione CallKit deve restare attiva fino a fine chiamata / decline esplicito.

      final callData = <String, dynamic>{
        'callId': callId,
        'callType': callType,
        'callerUserId': callerUserId,
        'conversationId': conversationId,
        'callerName': callerName,
        'avatarUrl': avatarUrl,
      };

      final nav = navigatorKey.currentState;
      if (nav != null) {
        CallService().setIncomingCallContext(
          callId: callId,
          callType: callType,
          remoteUserId: callerUserId,
          remoteUserName: callerName,
          remoteUserAvatar: avatarUrl,
          conversationId: conversationId,
        );
        await CallService().onAcceptedFromNative(callId);
        // iOS: NON chiamare setCallConnected — nel plugin chiama CallManager.connectedCall che fa
        // CXAnswerCallAction di nuovo → secondo ACTION_CALL_ACCEPT + payload self.data default (appName Callkit, configureAudioSession true).
        if (kIsWeb || !Platform.isIOS) {
          try {
            await FlutterCallkitIncoming.setCallConnected(callId);
          } catch (_) {}
        } else {
          debugPrint(
            '[CallKit-iOS] skip setCallConnected on iOS path context=VoipService._onAccept callId=$callId',
          );
          await ApiService().postLog(
            '[CallKit-iOS] skip setCallConnected after native accept callId=$callId (evita duplicate CXAnswerCallAction)',
          );
        }

        if (!nav.mounted) return;
        if (CallKitBridge.instance.isCallUiHandledFor(
          callId,
          includeNativeAnswered: false,
        )) {
          await ApiService().postLog(
            '[REMOTE-DEBUG] [VoipService._onAccept] skip push, call UI already handled callId=$callId',
          );
          return;
        }
        // Se la chiamata è già ended (caller ha chiuso rapidamente), non aprire la CallScreen
        if (CallService().isEnded) {
          await ApiService().postLog(
            '[REMOTE-DEBUG] [VoipService._onAccept] abort: call already ended callId=$callId',
          );
          // Forza chiusura CallKit
          try { await FlutterCallkitIncoming.endCall(callId); } catch (_) {}
          return;
        }
        // Non await: il Future di push completa al pop; markNavigated deve essere subito dopo l'ingresso in stack.
        nav.push(
          MaterialPageRoute(
            builder: (_) => CallScreen(
              conversationId: conversationId,
              callType: callType,
              isIncoming: true,
              callId: callId,
              remoteUserId: callerUserId,
              remoteUserName: callerName,
              remoteUserAvatar: avatarUrl,
              skipRingingSound: true,
              answeredFromCallKit: true,
            ),
          ),
        );
        CallKitBridge.instance.markNavigated(callId);
      } else {
        // Cold start: HomeScreen imposta context e chiama onAcceptedFromNative.
        _pendingAcceptedCall = callData;
      }
    } finally {
      _nativeAcceptInFlight.remove(callId);
    }
  }

  static Map<String, dynamic> _getHeadersFromBody(dynamic body) {
    if (body == null) return <String, dynamic>{};
    if (body is Map && body['headers'] is Map) {
      return Map<String, dynamic>.from(body['headers'] as Map);
    }
    try {
      final h = (body as dynamic).headers;
      if (h is Map) return Map<String, dynamic>.from(h);
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// Extra CallKit (PushKit / plugin) — spesso contiene callerUserId, conversationId.
  static Map<String, dynamic> _getExtraFromBody(dynamic body) {
    if (body == null) return <String, dynamic>{};
    if (body is Map && body['extra'] is Map) {
      return Map<String, dynamic>.from(body['extra'] as Map);
    }
    try {
      final e = (body as dynamic).extra;
      if (e is Map) return Map<String, dynamic>.from(e);
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// Merge extra + headers + [pending_call_data] (stesso callId) per non perdere il caller su accept nativo.
  Future<Map<String, dynamic>> _resolveIncomingContext(
    String callId,
    dynamic body,
  ) async {
    final extra = _getExtraFromBody(body);
    final headers = _getHeadersFromBody(body);
    final merged = <String, dynamic>{...extra, ...headers};

    var callerUserId = int.tryParse(merged['callerUserId']?.toString() ?? '') ??
        int.tryParse(merged['caller_id']?.toString() ?? '') ??
        0;
    var conversationId =
        merged['conversationId']?.toString() ?? merged['conversation_id']?.toString() ?? '';
    var callType =
        merged['callType']?.toString() ?? merged['call_type']?.toString() ?? 'audio';
    var callerName = _getNameCallerFromBody(body);
    if (callerName.isEmpty) {
      callerName = merged['callerName']?.toString() ??
          merged['caller_name']?.toString() ??
          merged['nameCaller']?.toString() ??
          '';
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('pending_call_data');
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        if (normalizeCallId(m['callId']?.toString()) == callId) {
          if (callerUserId == 0) {
            callerUserId =
                int.tryParse(m['callerUserId']?.toString() ?? '') ?? 0;
          }
          if (conversationId.isEmpty) {
            conversationId = m['conversationId']?.toString() ?? '';
          }
          final pt = m['callType']?.toString();
          if (pt != null && pt.isNotEmpty) callType = pt;
          if (callerName.isEmpty) {
            callerName = m['callerName']?.toString() ?? '';
          }
        }
      } catch (_) {}
    }

    await ApiService().postLog(
      '[REMOTE-DEBUG] [VoipService._resolveIncomingContext] callId=$callId callerUserId=$callerUserId conversationId=$conversationId callType=$callType extraKeys=${extra.keys.toList()} headerKeys=${headers.keys.toList()}',
    );
    return <String, dynamic>{
      'callerUserId': callerUserId,
      'conversationId': conversationId,
      'callType': callType,
      'callerName': callerName,
    };
  }

  static String _getNameCallerFromBody(dynamic body) {
    if (body == null) return '';
    if (body is Map) return (body['nameCaller'] ?? '').toString();
    try {
      return ((body as dynamic).nameCaller)?.toString() ?? '';
    } catch (_) {}
    return '';
  }

  void _onDecline(dynamic body) async {
    final id = _extractCallIdFromBody(body);
    await ApiService().postLog('[VoipService._onDecline] called, callId=$id');
    _callKitAnswered = false;
    _callKitIncomingPresented = false;
    if (id.isNotEmpty) {
      CallKitBridge.instance.clear(id);
      _nativeAcceptInFlight.remove(id);
    } else {
      ApiService().postLog('[VoipService._onDecline] no callId in body, skipping bridge/WS');
    }
    if (id.isEmpty) return;

    final activeCallId = CallService().state.callId;
    if (activeCallId != null && activeCallId != id) {
      ApiService().postLog(
        '[VoipService._onDecline] SKIP rejectCall: declining old call $id but active is $activeCallId',
      );
      FlutterCallkitIncoming.endCall(id);
      return;
    }

    CallService().ensureConnected();
    CallService().rejectCall(id);
    FlutterCallkitIncoming.endCall(id);
  }
}
