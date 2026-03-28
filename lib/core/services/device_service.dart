import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:device_imei/device_imei.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import 'api_service.dart';

class DeviceService {
  static final DeviceService instance = DeviceService._();
  DeviceService._();

  static const _kRegistrationId = 'axphone_device_registration_imei';

  /// Keychain / Keystore: dopo il primo valore letto non cambia finché l’utente non
  /// cancella dati app / reinstalla (su iOS l’IFV letto al primo avvio può comunque
  /// differire tra reinstall — vedi documentazione Apple su identifierForVendor).
  static const _secureDevice = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Identità inviata al server come `imei`: persistita in modo che **ogni sessione**
  /// usi lo stesso valore (evita letture incoerenti). Android: IMEI o Android ID;
  /// iOS: IFV (non esiste IMEI pubblico) o UUID di fallback.
  Future<String?> getStableHardwareIdentity() async {
    final cached = await _secureDevice.read(key: _kRegistrationId);
    if (cached != null && cached.isNotEmpty) return cached;

    String? computed;
    if (Platform.isIOS) {
      final d = await DeviceInfoPlugin().iosInfo;
      computed = d.identifierForVendor;
      if (computed == null || computed.isEmpty) {
        computed = const Uuid().v4();
      }
    } else if (Platform.isAndroid) {
      if (await Permission.phone.request().isGranted) {
        try {
          final raw = await DeviceImei().getDeviceImei();
          if (raw != null && raw.isNotEmpty) {
            final t = raw.trim();
            if (t.length >= 8) computed = t;
          }
        } catch (_) {}
      }
      if (computed == null || computed.isEmpty) {
        try {
          const plugin = AndroidId();
          final id = await plugin.getId();
          if (id != null && id.isNotEmpty) computed = id;
        } catch (_) {}
      }
    }
    if (computed == null || computed.isEmpty) return null;
    await _secureDevice.write(key: _kRegistrationId, value: computed);
    return computed;
  }

  Future<String?> getDeviceId() => getStableHardwareIdentity();

  Future<Map<String, dynamic>> getDeviceInfo() async {
    final info = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();
    final appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    final hardwareId = await getStableHardwareIdentity();
    if (hardwareId == null || hardwareId.isEmpty) {
      throw StateError('Impossibile determinare identità dispositivo (IMEI/ID)');
    }

    if (Platform.isIOS) {
      final d = await info.iosInfo;
      return {
        'platform': 'ios',
        'imei': hardwareId,
        'device_id': hardwareId,
        'device_name': d.name,
        'device_model': d.model,
        'os_version': d.systemVersion,
        'app_version': appVersion,
      };
    }
    if (Platform.isAndroid) {
      final d = await info.androidInfo;
      return {
        'platform': 'android',
        'imei': hardwareId,
        'device_id': hardwareId,
        'device_name': d.device,
        'device_model': d.model,
        'os_version': d.version.release,
        'app_version': appVersion,
      };
    }
    throw UnsupportedError('Piattaforma non supportata');
  }

  Future<Position?> getCurrentPosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
    } catch (e) {
      return null;
    }
  }

  /// Returns [true] if registration succeeded, [false] if device is blocked (403).
  Future<bool> registerDevice() async {
    try {
      final deviceInfo = await getDeviceInfo();
      final position = await getCurrentPosition();
      if (position != null) {
        deviceInfo['last_lat'] = position.latitude;
        deviceInfo['last_lng'] = position.longitude;
      }
      await ApiService().post('/auth/devices/register/', body: deviceInfo);
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        return false;
      }
      rethrow;
    } catch (e) {
      if (e.toString().contains('403')) {
        return false;
      }
      rethrow;
    }
  }

  Future<void> updateLocation() async {
    try {
      final deviceInfo = await getDeviceInfo();
      final position = await getCurrentPosition();
      if (position == null) return;
      deviceInfo['last_lat'] = position.latitude;
      deviceInfo['last_lng'] = position.longitude;
      await ApiService().post('/auth/devices/register/', body: deviceInfo);
    } catch (_) {}
  }
}
