class AppConstants {
  AppConstants._();

  // Backend API URL — produzione axphone.it
  static const String baseUrl = 'https://axphone.it/api';

  // URL base per file media (senza /api) — usato per immagini, video, audio, documenti
  static const String mediaBaseUrl = 'https://axphone.it';

  // WebSocket URL — chat e chiamate (produzione)
  static const String wsBaseUrl = 'wss://axphone.it/ws/chat/';
  static const String wsUrl = 'wss://axphone.it/ws/chat/';
  /// WebSocket URL for call signaling (WebRTC).
  static const String wsCallsUrl = 'wss://axphone.it/ws/calls/';

  // Notify server (proprietario)
  static const String notifyBaseUrl = 'https://axphone.it/notify';
  static const String notifyServiceKey = 'd566d7caafae5a75537a08ed1318f854f971c3e20723e05cae8d73055e541b6c';

  // Assets
  static const String imgSfondo = 'assets/images/sfondo.png';
  static const String imgIcona = 'assets/images/icona.png';
  static const String imgTestoLogo = 'media/LogoAxphone_Testo.png';
  static const String imgGoogleIcon = 'assets/images/google_icon.png';
  static const String imgAppleIcon = 'assets/images/apple_icon.png';

  // Splash timing
  static const int splashDurationMs = 4000;

  // App
  static const String appName = 'AXPhone';
  static const String appTagline = 'Private & Secure Messaging';
}
