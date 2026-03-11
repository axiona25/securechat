import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class LocalNotificationService {
  LocalNotificationService._();
  static final instance = LocalNotificationService._();

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
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: message.data['source_id'],
    );
  }

  /// Show a custom notification (not from FCM)
  Future<void> show({
    required String title,
    required String body,
    String? payload,
    String channelId = 'messages',
  }) async {
    if (!_initialized) await init();

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
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
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
    debugPrint('[LocalNotif] Tapped: ${response.payload}');
    // TODO: navigate to chat
  }
}
