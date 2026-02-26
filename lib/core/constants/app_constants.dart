class AppConstants {
  AppConstants._();

  // Backend API URL (127.0.0.1 per simulatore iOS — localhost può non essere raggiungibile)
  // Per Android Emulator: http://10.0.2.2:8000/api
  // Per iOS Simulator: http://127.0.0.1:8000/api
  // Per device fisico: http://TUO_IP_LOCALE:8000/api (es. http://192.168.1.100:8000/api)
  static const String baseUrl = 'http://127.0.0.1:8000/api';

  // URL base per file media (senza /api) — usato per immagini, video, audio, documenti
  static const String mediaBaseUrl = 'http://127.0.0.1:8000';

  // WebSocket URL — 127.0.0.1 per simulatore iOS (localhost non raggiungibile per WS)
  // Per Android Emulator: ws://10.0.2.2:8000/ws/chat/
  // Per iOS Simulator: ws://127.0.0.1:8000/ws/chat/
  static const String wsBaseUrl = 'ws://127.0.0.1:8000/ws/chat/';
  static const String wsUrl = 'ws://127.0.0.1:8000/ws/chat/';

  // Assets
  static const String imgSfondo = 'assets/images/sfondo.png';
  static const String imgIcona = 'assets/images/icona.png';
  static const String imgTestoLogo = 'assets/images/testo_logo.png';
  static const String imgGoogleIcon = 'assets/images/google_icon.png';
  static const String imgAppleIcon = 'assets/images/apple_icon.png';

  // Splash timing
  static const int splashDurationMs = 4000;

  // App
  static const String appName = 'SecureChat';
  static const String appTagline = 'Private & Secure Messaging';
}
