import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../constants/app_constants.dart';
import 'local_notification_service.dart';

class SecureChatNotifyService {
  static final SecureChatNotifyService _instance =
      SecureChatNotifyService._internal();
  factory SecureChatNotifyService() => _instance;
  SecureChatNotifyService._internal();

  static const String _notifyBaseUrl = AppConstants.notifyBaseUrl;
  static const MethodChannel _apnsChannel =
      MethodChannel('com.axphone.app/apns');

  WebSocketChannel? _wsChannel;
  Timer? _reconnectTimer;
  Timer? _pollingTimer;
  Timer? _heartbeatTimer;
  bool _isConnected = false;
  bool _isInitialized = false;
  String? _deviceToken;
  String? _apnsToken;
  int? _userId;

  final StreamController<Map<String, dynamic>> _notificationController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get notificationStream =>
      _notificationController.stream;

  void Function(Map<String, dynamic>)? onMessage;
  void Function(Map<String, dynamic>)? onCall;
  void Function(Map<String, dynamic>)? onCallEvent;
  void Function(String userId, bool isTyping)? onTyping;

  Future<void> init({required int userId}) async {
    _userId = userId;
    _isInitialized = true;
    debugPrint('[NotifyService] Inizializzazione per user $userId');
    await _initDeviceToken();
    await _requestApnsPermissionsAndToken();
    await _registerDevice();
    _connectWebSocket();
  }

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

  Future<void> _initDeviceToken() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceToken = prefs.getString('securechat_device_token');
    if (_deviceToken == null) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _deviceToken = 'securechat_ios_$ts';
      await prefs.setString('securechat_device_token', _deviceToken!);
    }
    debugPrint('[NotifyService] Device token: $_deviceToken');
  }

  Future<void> _requestApnsPermissionsAndToken() async {
    if (!Platform.isIOS) return;
    try {
      final granted =
          await _apnsChannel.invokeMethod<bool>('requestPermissions');
      debugPrint('[NotifyService] Permessi notifiche: $granted');
      final token =
          await _apnsChannel.invokeMethod<String>('getApnsToken');
      if (token != null && token.isNotEmpty) {
        _apnsToken = token;
        debugPrint('[NotifyService] APNs token: ${token.substring(0, 20)}...');
      }
    } catch (e) {
      debugPrint('[NotifyService] Errore APNs: $e');
    }
  }

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
        headers: {'Content-Type': 'application/json', ..._serviceKeyHeader()},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        debugPrint('[NotifyService] Dispositivo registrato OK');
        return true;
      }
      debugPrint('[NotifyService] Errore registrazione: ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[NotifyService] Errore registrazione: $e');
      return false;
    }
  }

  Future<void> unregisterDevice() async {
    if (_deviceToken == null || _userId == null) return;
    try {
      await http.post(
        Uri.parse('$_notifyBaseUrl/unregister'),
        headers: {'Content-Type': 'application/json', ..._serviceKeyHeader()},
        body: jsonEncode({
          'user_id': _userId.toString(),
          'device_token': _deviceToken,
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[NotifyService] Errore deregistrazione: $e');
    }
  }

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
      debugPrint('[NotifyService] WebSocket connesso');
    } catch (e) {
      debugPrint('[NotifyService] Errore WebSocket: $e');
      _isConnected = false;
      _startPolling();
    }
  }

  void _handleWebSocketMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';
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
      }
    } catch (e) {
      debugPrint('[NotifyService] Errore parsing WS: $e');
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
      if (_isInitialized) _connectWebSocket();
    });
    _startPolling();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _wsChannel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer =
        Timer.periodic(const Duration(seconds: 10), (_) async {
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
        final notifications =
            data['notifications'] as List<dynamic>? ?? [];
        for (final notif in notifications) {
          _handleWebSocketMessage(jsonEncode(notif));
        }
      }
    } catch (_) {}
  }

  void _handleMessageNotification(Map<String, dynamic> data) {
    onMessage?.call(data);
    final title = data['title'] as String? ??
        data['sender_name'] as String? ??
        'Nuovo messaggio';
    final body =
        data['body'] as String? ?? data['message'] as String? ?? '';
    LocalNotificationService.instance.showFromPush({
      'title': title,
      'body': body,
      'conversation_id':
          data['conversation_id']?.toString() ?? '',
    });
  }

  Future<void> sendTypingStart({required String recipientId}) async {
    try {
      await http.post(
        Uri.parse('$_notifyBaseUrl/typing/start'),
        headers: {
          'Content-Type': 'application/json',
          ..._serviceKeyHeader()
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
          ..._serviceKeyHeader()
        },
        body: jsonEncode({
          'user_id': _userId.toString(),
          'recipient_id': recipientId,
          'device_token': _deviceToken,
        }),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Map<String, String> _serviceKeyHeader() {
    const key = AppConstants.notifyServiceKey;
    if (key.isEmpty) return {};
    return {'X-Notify-Service-Key': key};
  }

  bool get isConnected => _isConnected;
  String? get deviceToken => _deviceToken;
}
