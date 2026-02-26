import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'permission_service.dart';

class LocationResult {
  final double latitude;
  final double longitude;
  final String? name;
  final String? address;

  LocationResult({
    required this.latitude,
    required this.longitude,
    this.name,
    this.address,
  });
}

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  Future<LocationResult?> getCurrentLocation() async {
    final granted = await PermissionService.requestLocation();
    if (!granted) return null;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      String? name;
      String? address;
      try {
        final placemarks = await placemarkFromCoordinates(
          position.latitude,
          position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          name = place.name ?? place.thoroughfare ?? place.subLocality;
          final parts = <String>[
            if (place.thoroughfare != null) place.thoroughfare!,
            if (place.subLocality != null) place.subLocality!,
            if (place.locality != null) place.locality!,
          ];
          address = parts.join(', ');
        }
      } catch (_) {}

      return LocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        name: name,
        address: address,
      );
    } catch (e) {
      return null;
    }
  }
}
