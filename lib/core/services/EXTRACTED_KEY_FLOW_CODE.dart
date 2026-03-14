import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../constants/app_constants.dart';
import 'local_notification_service.dart';

/// SecureChat Notify Service
/// Gestisce registrazione APNs, WebSocket real-time e polling fallback
/// verso il server notify proprietario (FastAPI su porta 8002).
class SecureChatNotifyService {
  static final SecureChatNotifyService _instance =
      SecureChatNotifyService._internal();
  factory SecureChatNotifyService() => _instance;
  SecureChatNotifyService._internal();

  // ── Configurazione ──────────────────────────────────────────────────────
  /// URL base del notify server (senza slash finale)
  /// In produzione: https://axphone.it/notify
  /// In development: http://206.189.59.87/notify
  static const String _notifyBaseUrl = AppConstants.notifyBaseUrl;

  // ── Canale nativo per APNs token ────────────────────────────────────────
  static const MethodChannel _apnsChannel =
      MethodChannel('com.axphone.app/apns');

  // ── Stato interno ────────────────────────────────────────────────────────
  WebSocketChannel? _wsChannel;
  Timer? _reconnectTimer;
  Timer? _pollingTimer;
  Timer? _heartbeatTimer;
  bool _isConnected = false;
  bool _isInitialized = false;
  String? _deviceToken;
  String? _apnsToken;
  int? _userId;

  // ── Stream controller per notifiche in arrivo ────────────────────────────
  final StreamController<Map<String, dynamic>> _notificationController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get notificationStream =>
      _notificationController.stream;

  // ── Callback per notifiche specifiche ────────────────────────────────────
  void Function(Map<String, dynamic>)? onMessage;
  void Function(Map<String, dynamic>)? onCall;
  void Function(Map<String, dynamic>)? onCallEvent;
  void Function(String userId, bool isTyping)? onTyping;

  // ── Init principale ──────────────────────────────────────────────────────

  /// Inizializza il servizio dopo il login.
  /// [userId] è l'ID utente corrente.
  Future<void> init({required int userId}) async {
    _userId = userId;
    _isInitialized = true;

    debugPrint('[NotifyService] Inizializzazione per user $userId');

    // 1. Genera o recupera device token locale
    await _initDeviceToken();

    // 2. Richiedi permessi APNs e ottieni token
    await _requestApnsPermissionsAndToken();

    // 3. Registra dispositivo al notify server
    await _registerDevice();

    // 4. Connetti WebSocket
    _connectWebSocket();
  }

  /// Chiude il servizio al logout.
  Future<void> dispose() async {
    _isInitialized = false;
    _userId = null;
    _reconnectTimer?.cancel();
    _pollingTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _wsChannel?.sink.close();
    _wsChannel = null;
    _isConnected = false;
    debugPrint('[NotifyService] Servizio chiuso');
  }

  // ── Device Token ─────────────────────────────────────────────────────────

  Future<void> _initDeviceToken() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceToken = prefs.getString('securechat_device_token');
    if (_deviceToken == null) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _deviceToken = 'securechat_ios_$ts';
      await prefs.setString('securechat_device_token', _deviceToken!);
      debugPrint('[NotifyService] Nuovo device token: $_deviceToken');
    } else {
      debugPrint('[NotifyService] Device token esistente: $_deviceToken');
    }
  }

  // ── APNs Permission + Token ───────────────────────────────────────────────

  Future<void> _requestApnsPermissionsAndToken() async {
    if (!Platform.isIOS) return;
    try {
      // Richiedi permessi notifiche
      final granted = await _apnsChannel.invokeMethod<bool>('requestPermissions');
      debugPrint('[NotifyService] Permessi notifiche: $granted');

      // Ottieni token APNs
      final token = await _apnsChannel.invokeMethod<String>('getApnsToken');
      if (token != null && token.isNotEmpty) {
        _apnsToken = token;
        debugPrint('[NotifyService] APNs token: ${token.substring(0, 20)}...');
      } else {
        debugPrint('[NotifyService] APNs token non disponibile');
      }
    } catch (e) {
      debugPrint('[NotifyService] Errore APNs: $e');
    }
  }

  // ── Registrazione dispositivo ─────────────────────────────────────────────

  Future<bool> _registerDevice() async {
    if (_deviceToken == null || _userId == null) return false;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final appVersion = packageInfo.version;
      final platform = Platform.isIOS ? 'ios' : 'android';

      final payload = <String, dynamic>{
        'device_token': _deviceToken,
        'user_id': _userId.toString(),
        'platform': platform,
        'app_version': appVersion,
      };

      if (Platform.isIOS && _apnsToken != null) {
        payload['apns_token'] = _apnsToken;
        payload['apns_topic'] = 'com.axphone.app';
        payload['apns_environment'] = 'production';
      }

      final response = await http.post(
        Uri.parse('$_notifyBaseUrl/register'),
        headers: {
          'Content-Type': 'application/json',
          ..._serviceKeyHeader(),
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint('[NotifyService] Dispositivo registrato ✅');
        return true;
      } else {
        debugPrint('[NotifyService] Errore registrazione: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('[NotifyService] Errore registrazione dispositivo: $e');
      return false;
    }
  }

  /// Deregistra il dispositivo al logout.
  Future<void> unregisterDevice() async {
    if (_deviceToken == null || _userId == null) return;
    try {
      await http.post(
        Uri.parse('$_notifyBaseUrl/unregister'),
        headers: {
          'Content-Type': 'application/json',
          ..._serviceKeyHeader(),
        },
        body: jsonEncode({
          'user_id': _userId.toString(),
          'device_token': _deviceToken,
        }),
      ).timeout(const Duration(seconds: 5));
      debugPrint('[NotifyService] Dispositivo deregistrato');
    } catch (e) {
      debugPrint('[NotifyService] Errore deregistrazione: $e');
    }
  }

  // ── WebSocket ─────────────────────────────────────────────────────────────

  void _connectWebSocket() {
    if (_deviceToken == null) return;

    try {
      final wsUrl = _notifyBaseUrl
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
      final uri = Uri.parse('$wsUrl/ws/$_deviceToken');

      debugPrint('[NotifyService] Connessione WebSocket: $uri');

      _wsChannel = IOWebSocketChannel.connect(
        uri,
        connectTimeout: const Duration(seconds: 10),
      );

      _wsChannel!.stream.listen(
        _handleWebSocketMessage,
        onError: _handleWebSocketError,
        onDone: _handleWebSocketDone,
      );

      _isConnected = true;
      _pollingTimer?.cancel();
      _startHeartbeat();
      debugPrint('[NotifyService] WebSocket connesso ✅');
    } catch (e) {
      debugPrint('[NotifyService] Errore connessione WebSocket: $e');
      _isConnected = false;
      _startPolling();
    }
  }

  void _handleWebSocketMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';
      debugPrint('[NotifyService] WS messaggio: type=$type');

      _notificationController.add(data);

      switch (type) {
        case 'notification':
        case 'message':
          _handleMessageNotification(data);
          break;
        case 'call':
          onCall?.call(data);
          break;
        case 'call_event':
        case 'call_status':
          onCallEvent?.call(data);
          break;
        case 'typing_start':
          onTyping?.call(data['user_id']?.toString() ?? '', true);
          break;
        case 'typing_stop':
          onTyping?.call(data['user_id']?.toString() ?? '', false);
          break;
        case 'pong':
          debugPrint('[NotifyService] Pong ricevuto ✅');
          break;
      }
    } catch (e) {
      debugPrint('[NotifyService] Errore parsing WS message: $e');
    }
  }

  void _handleWebSocketError(dynamic error) {
    debugPrint('[NotifyService] WebSocket errore: $error');
    _isConnected = false;
    _scheduleReconnect();
  }

  void _handleWebSocketDone() {
    debugPrint('[NotifyService] WebSocket chiuso');
    _isConnected = false;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_isInitialized) {
        debugPrint('[NotifyService] Tentativo riconnessione WebSocket...');
        _connectWebSocket();
      }
    });
    _startPolling();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _wsChannel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (e) {
        debugPrint('[NotifyService] Heartbeat fallito: $e');
      }
    });
  }

  // ── Polling fallback ──────────────────────────────────────────────────────

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isConnected) {
        _pollingTimer?.cancel();
        return;
      }
      await _pollNotifications();
    });
  }

  Future<void> _pollNotifications() async {
    if (_deviceToken == null) return;
    try {
      final response = await http.get(
        Uri.parse('$_notifyBaseUrl/poll/$_deviceToken'),
        headers: _serviceKeyHeader(),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final notifications = data['notifications'] as List<dynamic>? ?? [];
        for (final notif in notifications) {
          _handleWebSocketMessage(jsonEncode(notif));
        }
      }
    } catch (e) {
      debugPrint('[NotifyService] Polling errore: $e');
    }
  }

  // ── Gestione notifiche messaggi ───────────────────────────────────────────

  void _handleMessageNotification(Map<String, dynamic> data) {
    final messageId = data['message_id']?.toString() ?? data['id']?.toString();

    // Callback custom
    onMessage?.call(data);

    // Mostra notifica locale in foreground
    final title = data['title'] as String? ?? data['sender_name'] as String? ?? 'Nuovo messaggio';
    final body = data['body'] as String? ?? data['message'] as String? ?? '';

    LocalNotificationService.instance.showFromPush({
      'title': title,
      'body': body,
      'conversation_id': data['conversation_id']?.toString() ?? '',
    });
  }

  // ── Typing indicator ──────────────────────────────────────────────────────

  Future<void> sendTypingStart({required String recipientId}) async {
    try {
      await http.post(
        Uri.parse('$_notifyBaseUrl/typing/start'),
        headers: {
          'Content-Type': 'application/json',
          ..._serviceKeyHeader(),
        },
        body: jsonEncode({
          'user_id': _userId.toString(),
          'recipient_id': recipientId,
          'device_token': _deviceToken,
        }),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> sendTypingStop({required String recipientId}) async {
    try {
      await http.post(
        Uri.parse('$_notifyBaseUrl/typing/stop'),
        headers: {
          'Content-Type': 'application/json',
          ..._serviceKeyHeader(),
        },
        body: jsonEncode({
          'user_id': _userId.toString(),
          'recipient_id': recipientId,
          'device_token': _deviceToken,
        }),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  // ── Utilità ───────────────────────────────────────────────────────────────

  Map<String, String> _serviceKeyHeader() {
    const key = AppConstants.notifyServiceKey;
    if (key.isEmpty) return {};
    return {'X-Notify-Service-Key': key};
  }

  bool get isConnected => _isConnected;
  String? get deviceToken => _deviceToken;
}
