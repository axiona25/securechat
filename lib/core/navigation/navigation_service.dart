import 'package:flutter/material.dart';
import '../../main.dart' as main_app;

class NavigationService {
  static GlobalKey<NavigatorState> get navigatorKey => main_app.navigatorKey;
}
