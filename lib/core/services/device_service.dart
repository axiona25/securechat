import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'auth_service.dart';
import '../navigation/navigation_service.dart';

class DeviceService {
  static final DeviceService instance = DeviceService._();
  DeviceService._();

  static const String _deviceIdKey = 'axphone_device_id';

  Future<String?> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_deviceIdKey)) return prefs.getString(_deviceIdKey);
    final info = DeviceInfoPlugin();
    String? id;
    if (Platform.isIOS) {
      final d = await info.iosInfo;
      id = d.identifierForVendor;
    } else if (Platform.isAndroid) {
      final d = await info.androidInfo;
      id = d.id;
    }
    if (id != null) await prefs.setString(_deviceIdKey, id);
    return id;
  }

  Future<Map<String, dynamic>> getDeviceInfo() async {
    final info = DeviceInfoPlugin();
    if (Platform.isIOS) {
      final d = await info.iosInfo;
      return {
        'platform': 'ios',
        'device_id': d.identifierForVendor ?? '',
        'device_name': d.name,
        'device_model': d.model,
        'os_version': d.systemVersion,
      };
    } else {
      final d = await info.androidInfo;
      return {
        'platform': 'android',
        'device_id': d.id,
        'device_name': d.device,
        'device_model': d.model,
        'os_version': d.version.release,
      };
    }
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

  Future<void> registerDevice() async {
    try {
      final deviceInfo = await getDeviceInfo();
      final position = await getCurrentPosition();
      if (position != null) {
        deviceInfo['last_lat'] = position.latitude;
        deviceInfo['last_lng'] = position.longitude;
      }
      await ApiService().post('/auth/devices/register/', body: deviceInfo);
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        await AuthService().logout();
        final context = NavigationService.navigatorKey.currentContext;
        if (context != null) {
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
        }
      }
    } catch (e) {
      if (e.toString().contains('403')) {
        await AuthService().logout();
        final context = NavigationService.navigatorKey.currentContext;
        if (context != null) {
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
        }
      }
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
