import 'package:flutter/foundation.dart';

/// Global notifier to bust avatar image cache after upload.
class AvatarCacheService {
  AvatarCacheService._();
  static final instance = AvatarCacheService._();

  final ValueNotifier<int> cacheBuster = ValueNotifier<int>(0);

  void bust() {
    cacheBuster.value = DateTime.now().millisecondsSinceEpoch;
  }
}
