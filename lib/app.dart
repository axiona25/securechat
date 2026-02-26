import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/routes/app_router.dart';
import 'core/services/api_service.dart';

class SecureChatApp extends StatefulWidget {
  const SecureChatApp({super.key});

  @override
  State<SecureChatApp> createState() => _SecureChatAppState();
}

class _SecureChatAppState extends State<SecureChatApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setUserOffline();
    } else if (state == AppLifecycleState.resumed) {
      _setUserOnline();
    }
  }

  Future<void> _setUserOffline() async {
    if (!ApiService().isAuthenticated) return;
    try {
      await ApiService().post('/auth/logout/', body: {});
    } catch (_) {}
  }

  Future<void> _setUserOnline() async {
    if (!ApiService().isAuthenticated) return;
    try {
      await ApiService().post('/auth/heartbeat/', body: {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      initialRoute: AppRouter.splash,
      onGenerateRoute: AppRouter.generateRoute,
    );
  }
}
