import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/location_service.dart';

class LocationPickerSheet extends StatefulWidget {
  const LocationPickerSheet({super.key});

  static Future<LocationResult?> show(BuildContext context) {
    return showModalBottomSheet<LocationResult>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const LocationPickerSheet(),
    );
  }

  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  final LocationService _locationService = LocationService();
  bool _isLoading = false;
  LocationResult? _currentLocation;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchCurrentLocation();
  }

  Future<void> _fetchCurrentLocation() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await _locationService.getCurrentLocation();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _currentLocation = result;
        if (result == null) {
          _error = 'Unable to get your location. Please check permissions and GPS.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Share Location',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 24),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Column(
                  children: [
                    CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
                    SizedBox(height: 16),
                    Text(
                      'Getting your location...',
                      style: TextStyle(fontSize: 14, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    const Icon(Icons.location_off_outlined,
                        color: AppColors.textDisabled, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(fontSize: 14, color: AppColors.textTertiary),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _fetchCurrentLocation,
                      child: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            if (_currentLocation != null) ...[
              Container(
                height: 160,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.bgIce,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(double.infinity, 160),
                      painter: _MapGridPainter(),
                    ),
                    const Icon(Icons.location_on, color: AppColors.error, size: 40),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_currentLocation!.name != null)
                Text(
                  _currentLocation!.name!,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              if (_currentLocation!.address != null) ...[
                const SizedBox(height: 4),
                Text(
                  _currentLocation!.address!,
                  style: const TextStyle(fontSize: 13, color: AppColors.textTertiary),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '${_currentLocation!.latitude.toStringAsFixed(5)}, '
                '${_currentLocation!.longitude.toStringAsFixed(5)}',
                style: const TextStyle(fontSize: 11, color: AppColors.textDisabled),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(_currentLocation),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textOnPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.send_rounded, size: 20),
                  label: const Text(
                    'Send Current Location',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.divider.withValues(alpha: 0.4)
      ..strokeWidth = 0.5;

    for (double y = 0; y < size.height; y += 20) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (double x = 0; x < size.width; x += 20) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
