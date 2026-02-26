import logging
from django.utils import timezone
from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework.throttling import UserRateThrottle
from .services import ShieldService
from .models import ThreatDetection, DeviceSecurityProfile

logger = logging.getLogger(__name__)


class ScanReportThrottle(UserRateThrottle):
    rate = '30/hour'


class SubmitScanReportView(APIView):
    """
    Receive security scan results from a client device.
    Analyzes the report against IOC database and returns risk assessment.
    """
    permission_classes = [IsAuthenticated]
    throttle_classes = [ScanReportThrottle]

    def post(self, request):
        scan_data = request.data
        device_id = scan_data.get('device_id')

        if not device_id:
            return Response({'error': 'device_id mancante.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            result = ShieldService.process_scan_report(
                user=request.user,
                device_id=device_id,
                scan_data=scan_data,
            )
            return Response(result)
        except Exception as e:
            logger.error(f'Shield scan error for {request.user.email}: {e}')
            return Response({'error': 'Errore durante l\'analisi.'},
                          status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class GetIOCUpdateView(APIView):
    """
    Get updated Indicators of Compromise for local scanning.
    Client caches these locally and checks periodically.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request):
        platform = request.query_params.get('platform', 'android')
        last_version = request.query_params.get('last_version', '')

        result = ShieldService.get_ioc_update(
            platform=platform,
            last_version=last_version,
        )
        return Response(result)


class DeviceDashboardView(APIView):
    """Get security overview for all user's devices"""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        result = ShieldService.get_device_dashboard(request.user)
        return Response(result)


class ThreatDetailView(APIView):
    """Get details of a specific threat detection"""
    permission_classes = [IsAuthenticated]

    def get(self, request, detection_id):
        try:
            detection = ThreatDetection.objects.get(
                id=detection_id, user=request.user
            )
        except ThreatDetection.DoesNotExist:
            return Response({'error': 'Rilevamento non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        return Response({
            'id': str(detection.id),
            'detection_type': detection.detection_type,
            'detection_detail': detection.detection_detail,
            'matched_value': detection.matched_value,
            'severity': detection.severity,
            'status': detection.status,
            'scan_type': detection.scan_type,
            'spyware_family': detection.threat_indicator.spyware_family if detection.threat_indicator else None,
            'spyware_description': detection.threat_indicator.description if detection.threat_indicator else None,
            'raw_evidence': detection.raw_evidence,
            'detected_at': detection.detected_at.isoformat(),
            'resolved_at': detection.resolved_at.isoformat() if detection.resolved_at else None,
        })


class ResolveThreatView(APIView):
    """Mark a threat as resolved or false positive"""
    permission_classes = [IsAuthenticated]

    def post(self, request, detection_id):
        resolution = request.data.get('resolution', 'resolved')  # resolved, false_positive, ignored

        try:
            detection = ThreatDetection.objects.get(
                id=detection_id, user=request.user
            )
        except ThreatDetection.DoesNotExist:
            return Response({'error': 'Rilevamento non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        valid_resolutions = ['resolved', 'false_positive', 'ignored']
        if resolution not in valid_resolutions:
            return Response({'error': f'Risoluzione non valida. Opzioni: {valid_resolutions}'},
                          status=status.HTTP_400_BAD_REQUEST)

        detection.status = resolution
        detection.resolved_at = timezone.now()
        detection.save(update_fields=['status', 'resolved_at'])

        # Update IOC statistics
        if detection.threat_indicator:
            if resolution == 'false_positive':
                detection.threat_indicator.false_positive_count += 1
                detection.threat_indicator.save(update_fields=['false_positive_count'])
            elif resolution == 'resolved':
                detection.threat_indicator.true_positive_count += 1
                detection.threat_indicator.save(update_fields=['true_positive_count'])

        return Response({'message': f'Minaccia segnata come {resolution}.'})


class EmergencyLockdownView(APIView):
    """
    Emergency lockdown: triggered when critical spyware is detected.
    Invalidates all sessions, revokes tokens, notifies user.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        device_id = request.data.get('device_id')

        try:
            device = DeviceSecurityProfile.objects.get(
                device_id=device_id, user=request.user
            )
        except DeviceSecurityProfile.DoesNotExist:
            return Response({'error': 'Device non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        # Invalidate all JWT tokens for this user
        from rest_framework_simplejwt.token_blacklist.models import OutstandingToken, BlacklistedToken
        tokens = OutstandingToken.objects.filter(user=request.user)
        for token in tokens:
            BlacklistedToken.objects.get_or_create(token=token)

        # Clear Firebase tokens (prevent push to compromised device)
        if hasattr(request.user, 'firebase_token'):
            request.user.firebase_token = ''
            request.user.save(update_fields=['firebase_token'])

        # Mark device as compromised
        device.risk_level = 'compromised'
        device.save(update_fields=['risk_level'])

        logger.critical(
            f'EMERGENCY LOCKDOWN: User {request.user.email}, '
            f'device {device_id}. All sessions revoked.'
        )

        return Response({
            'message': 'Lockdown di emergenza attivato. Tutti i token revocati. '
                      'Accedi da un dispositivo sicuro e cambia la password.',
            'action_required': [
                'Esegui un ripristino di fabbrica del dispositivo compromesso',
                'Cambia la password di SecureChat da un dispositivo sicuro',
                'Cambia le password di tutti gli account collegati',
                'Contatta un esperto di cybersecurity',
            ]
        })
