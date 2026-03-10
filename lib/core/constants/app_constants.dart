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
