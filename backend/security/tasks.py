"""
Celery tasks for SecureChat Shield.
Periodic security maintenance and IOC updates.
"""

from celery import shared_task
from django.utils import timezone
import logging

logger = logging.getLogger(__name__)


@shared_task
def seed_ioc_database():
    """Seed the IOC database with initial indicators"""
    from .models import ThreatIndicator, IOCDatabaseVersion
    from .ioc_database import get_initial_iocs

    iocs = get_initial_iocs()
    created_count = 0

    for ioc_data in iocs:
        _, created = ThreatIndicator.objects.get_or_create(
            ioc_type=ioc_data['ioc_type'],
            value=ioc_data['value'],
            defaults={
                'spyware_family': ioc_data.get('spyware_family', 'unknown'),
                'severity': ioc_data.get('severity', 3),
                'platform': ioc_data.get('platform', 'both'),
                'description': ioc_data.get('description', ''),
                'source': ioc_data.get('source', 'Internal'),
                'first_seen': timezone.now(),
            }
        )
        if created:
            created_count += 1

    # Create version
    version = timezone.now().strftime('%Y%m%d.%H%M')
    IOCDatabaseVersion.objects.create(
        version=version,
        ioc_count=ThreatIndicator.objects.filter(is_active=True).count(),
        changelog=f'Initial seed: {created_count} indicators',
        is_current=True,
    )

    logger.info(f'IOC database seeded: {created_count} new indicators, version {version}')
    return f'Seeded {created_count} IOCs'


@shared_task
def cleanup_old_detections():
    """Clean up resolved/old threat detections (keep 90 days)"""
    from .models import ThreatDetection, NetworkAnomalyLog

    cutoff = timezone.now() - timezone.timedelta(days=90)

    deleted_detections, _ = ThreatDetection.objects.filter(
        status__in=['resolved', 'false_positive', 'ignored'],
        detected_at__lt=cutoff,
    ).delete()

    deleted_logs, _ = NetworkAnomalyLog.objects.filter(
        detected_at__lt=cutoff,
    ).delete()

    logger.info(f'Shield cleanup: {deleted_detections} detections, {deleted_logs} network logs removed')


@shared_task
def check_stale_devices():
    """Alert about devices that haven't scanned in 7+ days"""
    from .models import DeviceSecurityProfile

    stale_cutoff = timezone.now() - timezone.timedelta(days=7)
    stale_devices = DeviceSecurityProfile.objects.filter(
        last_scan_at__lt=stale_cutoff,
        risk_level__in=['safe', 'low'],
    )

    for device in stale_devices:
        device.risk_level = 'low'  # Bump to low risk if not scanning
        device.save(update_fields=['risk_level'])

    logger.info(f'Stale device check: {stale_devices.count()} devices marked as low risk')
