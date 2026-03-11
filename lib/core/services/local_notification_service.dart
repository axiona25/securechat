import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Suono messaggi chat: solo da ChatSoundService (notification.wav). Su iOS il suono di sistema
/// delle local notification per i messaggi è disattivato (presentSound: false) per evitare doppio suono.

class LocalNotificationService {
  LocalNotificationService._();
  static final instance = LocalNotificationService._();

  /// Callback invocato al tap su notifica (payload = conversation_id o altro).
  static void Function(String? payload)? onNotificationTap;
  static void setNotificationTapCallback(void Function(String? payload)? callback) {
    onNotificationTap = callback;
  }

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onTap,
    );

    // Create Android notification channels
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'messages',
        'Messaggi',
        description: 'Notifiche nuovi messaggi',
        importance: Importance.high,
        playSound: true,
      ));
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'calls',
        'Chiamate',
        description: 'Notifiche chiamate',
        importance: Importance.max,
        playSound: true,
      ));
    }

    _initialized = true;
    debugPrint('[LocalNotif] Initialized');
  }

  /// Show a notification from an FCM RemoteMessage (foreground)
  Future<void> showFromFCM(RemoteMessage message) async {
    if (!_initialized) await init();

    final notification = message.notification;
    if (notification == null) return;

    final type = message.data['type'] ?? 'default';
    final channelId = _channelForType(type);
    final isChat = channelId == 'messages';
    if (Platform.isIOS && isChat) {
      debugPrint('[LocalNotif] chat notification shown with sound disabled');
    } else if (Platform.isIOS && !isChat) {
      debugPrint('[LocalNotif] non-chat notification sound unchanged');
    }

    await _plugin.show(
      id: notification.hashCode,
      title: notification.title ?? 'SecureChat',
      body: notification.body ?? '',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelId == 'messages' ? 'Messaggi' : (channelId == 'calls' ? 'Chiamate' : 'Notifiche'),
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: !isChat,
        ),
      ),
      payload: message.data['source_id'],
    );
  }

  /// Show a custom notification (not from FCM). Usato per messaggi chat da home_screen.
  /// Su iOS le notifiche chat hanno presentSound: false; il suono è solo da ChatSoundService.
  Future<void> show({
    required String title,
    required String body,
    String? payload,
    String channelId = 'messages',
  }) async {
    if (!_initialized) await init();

    final isChat = channelId == 'messages';
    if (Platform.isIOS && isChat) {
      debugPrint('[LocalNotif] chat notification shown with sound disabled');
    } else if (Platform.isIOS && !isChat) {
      debugPrint('[LocalNotif] non-chat notification sound unchanged');
    }

    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelId == 'messages' ? 'Messaggi' : 'Notifiche',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: !isChat,
        ),
      ),
      payload: payload,
    );
  }

  String _channelForType(String type) {
    switch (type) {
      case 'new_message':
      case 'message_reaction':
        return 'messages';
      case 'incoming_call':
      case 'missed_call':
        return 'calls';
      default:
        return 'default';
    }
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    debugPrint('[LocalNotif] Tapped: $payload');
    if (onNotificationTap != null) {
      onNotificationTap!(payload);
    }
  }
}
