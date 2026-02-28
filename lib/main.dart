import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/services/api_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// Handler per notifiche in background (deve essere top-level)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Gestione notifica in background
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase init (optional: add google-services.json / GoogleService-Info.plist)
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await messaging.getToken();
    debugPrint('FCM Token: $token');

    // Registra token FCM nel backend
    if (token != null) {
      try {
        final accessToken = ApiService().accessToken;
        if (accessToken != null) {
          final response = await http.post(
            Uri.parse('${AppConstants.baseUrl}/auth/fcm-token/'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'token': token}),
          );
          debugPrint('[FCM] Token registered: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('[FCM] Token registration error: $e');
      }
    }

    // Gestione notifiche in foreground
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('[FCM] Foreground message: ${message.notification?.title}');
      // La notifica in foreground è gestita dal polling/WebSocket
    });

    // Gestione tap su notifica
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('[FCM] Opened from notification: ${message.data}');
      // TODO: navigare alla chat corretta
    });
  } catch (e) {
    debugPrint('Firebase not configured: $e');
  }

  // Lock orientation to portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Transparent status bar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  runApp(const SecureChatApp());
}
