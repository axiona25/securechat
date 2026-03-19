import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/routes/app_router.dart';
import 'core/services/api_service.dart';
import 'core/l10n/app_localizations.dart';
import 'core/l10n/locale_provider.dart';

class SecureChatApp extends StatefulWidget {
  const SecureChatApp({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<SecureChatApp> createState() => _SecureChatAppState();
}

class _SecureChatAppState extends State<SecureChatApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Chiamata pendente da CallKit: gestita da HomeScreen._navigateToCallScreen
    // (setIncomingCallContext + acceptCall), evitando race con getPendingAcceptedCall.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Non segnalare offline quando l'app va in background: l'utente resta "online"
    // finché il WebSocket è aperto o finché non fa logout. Lo stato assente viene
    // impostato solo al logout esplicito o quando la rete/server disconnette il WS.
    if (state == AppLifecycleState.resumed) {
      _setUserOnline();
    }
  }

  Future<void> _setUserOnline() async {
    if (!ApiService().isAuthenticated) return;
    try {
      await ApiService().post('/auth/heartbeat/', body: {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: localeProvider,
      builder: (context, child) {
        return MaterialApp(
          navigatorKey: widget.navigatorKey,
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          locale: localeProvider.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          initialRoute: AppRouter.splash,
          onGenerateRoute: AppRouter.generateRoute,
        );
      },
    );
  }
}
