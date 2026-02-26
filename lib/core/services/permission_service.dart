import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  PermissionService._();

  static Future<bool> requestCamera() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  static Future<bool> requestMicrophone() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  static Future<bool> requestStorage() async {
    final status = await Permission.storage.request();
    if (status.isGranted) return true;
    final photos = await Permission.photos.request();
    return photos.isGranted;
  }

  static Future<bool> requestLocation() async {
    final status = await Permission.locationWhenInUse.request();
    return status.isGranted;
  }

  static Future<bool> requestContacts() async {
    final status = await Permission.contacts.request();
    return status.isGranted;
  }

  static Future<bool> checkCamera() async {
    return await Permission.camera.isGranted;
  }

  static Future<bool> checkMicrophone() async {
    return await Permission.microphone.isGranted;
  }

  static Future<bool> checkLocation() async {
    return await Permission.locationWhenInUse.isGranted;
  }

  static Future<bool> checkContacts() async {
    return await Permission.contacts.isGranted;
  }

  static Future<void> openSettingsIfDenied(PermissionStatus status) async {
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
  }
}
