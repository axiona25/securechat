import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
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
    final fcmToken = await messaging.getToken();
    debugPrint('FCM Token: $fcmToken');
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
