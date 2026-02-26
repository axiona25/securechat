"""
SecureChat Shield - Security Analysis Service
==============================================
Processes scan results from clients, correlates with IOC database,
generates alerts, and computes device risk scores.
"""

import logging
from datetime import timedelta
from django.utils import timezone
from django.db.models import Q, Count
from .models import (
    ThreatIndicator, DeviceSecurityProfile, ThreatDetection,
    NetworkAnomalyLog, IOCDatabaseVersion
)

logger = logging.getLogger(__name__)


class ShieldService:
    """Main service for SecureChat Shield threat analysis"""

    # Risk score weights
    RISK_WEIGHTS = {
        'is_rooted': 20,
        'is_debugger_attached': 30,
        'has_hooking_frameworks': 40,
        'has_suspicious_apps': 25,
        'has_network_anomalies': 15,
        'code_integrity_valid': -10,  # Negative = reduces risk when True
        'certificate_pinning_valid': -10,
        'secure_enclave_available': -5,
    }

    RISK_THRESHOLDS = {
        'safe': (0, 10),
        'low': (11, 25),
        'medium': (26, 45),
        'high': (46, 70),
        'critical': (71, 90),
        'compromised': (91, 200),
    }

    @classmethod
    def process_scan_report(cls, user, device_id, scan_data):
        """
        Process a security scan report from a client device.

        Args:
            user: User instance
            device_id: unique device identifier
            scan_data: dict with scan results from client

        Returns:
            dict with risk assessment and any detected threats
        """
        # Get or create device profile
        device, created = DeviceSecurityProfile.objects.update_or_create(
            user=user,
            device_id=device_id,
            defaults={
                'device_model': scan_data.get('device_model', ''),
                'os_type': scan_data.get('os_type', 'android'),
                'os_version': scan_data.get('os_version', ''),
                'app_version': scan_data.get('app_version', ''),
                'is_rooted': scan_data.get('is_rooted', False),
                'is_debugger_attached': scan_data.get('is_debugger_attached', False),
                'has_hooking_frameworks': scan_data.get('has_hooking_frameworks', False),
                'code_integrity_valid': scan_data.get('code_integrity_valid', True),
                'certificate_pinning_valid': scan_data.get('certificate_pinning_valid', True),
                'secure_enclave_available': scan_data.get('secure_enclave_available', True),
                'last_scan_at': timezone.now(),
            }
        )

        device.scan_count += 1
        detections = []

        # ── Check installed apps/packages against IOC database ──
        installed_packages = scan_data.get('installed_packages', [])
        suspicious_packages = ThreatIndicator.objects.filter(
            ioc_type='package',
            value__in=installed_packages,
            is_active=True,
        )
        for ioc in suspicious_packages:
            detection = ThreatDetection.objects.create(
                device=device,
                user=user,
                threat_indicator=ioc,
                detection_type='suspicious_package',
                detection_detail=f'Suspicious package installed: {ioc.value}',
                matched_value=ioc.value,
                severity=ioc.severity,
                scan_type=scan_data.get('scan_type', 'periodic'),
                raw_evidence={'package': ioc.value, 'family': ioc.spyware_family},
            )
            detections.append(detection)

        # ── Check running processes ──
        running_processes = scan_data.get('running_processes', [])
        suspicious_processes = ThreatIndicator.objects.filter(
            ioc_type='process',
            value__in=running_processes,
            is_active=True,
        )
        for ioc in suspicious_processes:
            detection = ThreatDetection.objects.create(
                device=device,
                user=user,
                threat_indicator=ioc,
                detection_type='suspicious_process',
                detection_detail=f'Suspicious process running: {ioc.value}',
                matched_value=ioc.value,
                severity=ioc.severity,
                scan_type=scan_data.get('scan_type', 'periodic'),
                raw_evidence={'process': ioc.value, 'family': ioc.spyware_family},
            )
            detections.append(detection)

        # ── Check file paths ──
        found_paths = scan_data.get('suspicious_paths_found', [])
        suspicious_paths = ThreatIndicator.objects.filter(
            ioc_type='file_path',
            value__in=found_paths,
            is_active=True,
        )
        for ioc in suspicious_paths:
            detection = ThreatDetection.objects.create(
                device=device,
                user=user,
                threat_indicator=ioc,
                detection_type='suspicious_file',
                detection_detail=f'Suspicious file found: {ioc.value}',
                matched_value=ioc.value,
                severity=ioc.severity,
                scan_type=scan_data.get('scan_type', 'periodic'),
                raw_evidence={'path': ioc.value, 'family': ioc.spyware_family},
            )
            detections.append(detection)

        # ── Check DNS queries / network connections ──
        dns_queries = scan_data.get('recent_dns_queries', [])
        network_connections = scan_data.get('active_connections', [])

        suspicious_domains = ThreatIndicator.objects.filter(
            ioc_type__in=['domain', 'dns'],
            is_active=True,
        )
        domain_set = {ioc.value: ioc for ioc in suspicious_domains}

        for query in dns_queries:
            if query in domain_set:
                ioc = domain_set[query]
                detection = ThreatDetection.objects.create(
                    device=device,
                    user=user,
                    threat_indicator=ioc,
                    detection_type='malicious_domain',
                    detection_detail=f'DNS query to known spyware domain: {query}',
                    matched_value=query,
                    severity=ioc.severity,
                    scan_type='network',
                    raw_evidence={'domain': query, 'family': ioc.spyware_family},
                )
                detections.append(detection)

                NetworkAnomalyLog.objects.create(
                    device=device,
                    user=user,
                    destination_domain=query,
                    is_suspicious=True,
                    suspicion_reason=f'Matches known {ioc.spyware_family} C2 domain',
                    matched_ioc=ioc,
                )

        suspicious_ips = ThreatIndicator.objects.filter(
            ioc_type='ip',
            is_active=True,
        )
        ip_set = {ioc.value: ioc for ioc in suspicious_ips}

        for conn in network_connections:
            ip = conn.get('ip', '')
            if ip in ip_set:
                ioc = ip_set[ip]
                detection = ThreatDetection.objects.create(
                    device=device,
                    user=user,
                    threat_indicator=ioc,
                    detection_type='malicious_connection',
                    detection_detail=f'Connection to known spyware IP: {ip}',
                    matched_value=ip,
                    severity=ioc.severity,
                    scan_type='network',
                    raw_evidence=conn,
                )
                detections.append(detection)

        # ── Check behavioral patterns ──
        behaviors = scan_data.get('behavioral_flags', [])
        behavior_iocs = ThreatIndicator.objects.filter(
            ioc_type='behavior',
            value__in=behaviors,
            is_active=True,
        )
        for ioc in behavior_iocs:
            detection = ThreatDetection.objects.create(
                device=device,
                user=user,
                threat_indicator=ioc,
                detection_type='suspicious_behavior',
                detection_detail=ioc.description,
                matched_value=ioc.value,
                severity=ioc.severity,
                scan_type='realtime',
                raw_evidence={'behavior': ioc.value},
            )
            detections.append(detection)

        # ── Compute risk score ──
        device.has_suspicious_apps = len(suspicious_packages) > 0
        device.has_network_anomalies = any(d.detection_type in ('malicious_domain', 'malicious_connection') for d in detections)
        device.threat_count = ThreatDetection.objects.filter(
            device=device, status='detected'
        ).count()

        risk_score = cls._compute_risk_score(device, detections)
        device.risk_level = cls._score_to_level(risk_score)
        device.save()

        # ── Build response ──
        response = {
            'device_id': device_id,
            'risk_level': device.risk_level,
            'risk_score': risk_score,
            'threats_found': len(detections),
            'threat_details': [
                {
                    'id': str(d.id),
                    'type': d.detection_type,
                    'detail': d.detection_detail,
                    'severity': d.severity,
                    'spyware_family': d.threat_indicator.spyware_family if d.threat_indicator else 'unknown',
                }
                for d in detections
            ],
            'recommendations': cls._generate_recommendations(device, detections),
            'scan_timestamp': timezone.now().isoformat(),
        }

        # Log critical detections
        if device.risk_level in ('critical', 'compromised'):
            logger.critical(
                f'SHIELD ALERT: Device {device_id} of {user.email} '
                f'risk={device.risk_level} score={risk_score} '
                f'threats={len(detections)}'
            )

        return response

    @classmethod
    def _compute_risk_score(cls, device, detections):
        """Compute a 0-100 risk score based on device state and detections"""
        score = 0

        # Device state factors
        for field, weight in cls.RISK_WEIGHTS.items():
            value = getattr(device, field, False)
            if weight < 0:
                # Negative weight = good thing when True
                if not value:
                    score += abs(weight)
            else:
                if value:
                    score += weight

        # Detection severity contributions
        for d in detections:
            if d.severity >= 5:
                score += 25
            elif d.severity >= 4:
                score += 15
            elif d.severity >= 3:
                score += 8
            else:
                score += 3

        return min(score, 100)

    @classmethod
    def _score_to_level(cls, score):
        """Convert numeric risk score to level string"""
        for level, (low, high) in cls.RISK_THRESHOLDS.items():
            if low <= score <= high:
                return level
        return 'compromised'

    @classmethod
    def _generate_recommendations(cls, device, detections):
        """Generate actionable security recommendations"""
        recs = []

        if device.is_rooted:
            recs.append({
                'priority': 'high',
                'action': 'remove_root',
                'message': 'Il tuo dispositivo è rootato/jailbroken. '
                          'Questo lo rende vulnerabile a spyware. '
                          'Ripristina il dispositivo alle impostazioni di fabbrica.',
            })

        if device.is_debugger_attached:
            recs.append({
                'priority': 'critical',
                'action': 'check_debugger',
                'message': 'È stato rilevato un debugger collegato al dispositivo. '
                          'Questo potrebbe indicare un attacco in corso. '
                          'Disconnetti il dispositivo da qualsiasi computer e riavvia.',
            })

        if device.has_hooking_frameworks:
            recs.append({
                'priority': 'critical',
                'action': 'remove_hooks',
                'message': 'Rilevati framework di hooking (Frida/Xposed). '
                          'Questi strumenti possono intercettare i tuoi messaggi. '
                          'Esegui un ripristino di fabbrica.',
            })

        if not device.code_integrity_valid:
            recs.append({
                'priority': 'high',
                'action': 'reinstall_app',
                'message': 'L\'integrità dell\'app SecureChat è compromessa. '
                          'Disinstalla e reinstalla l\'app dallo store ufficiale.',
            })

        spyware_detections = [d for d in detections if d.severity >= 5]
        if spyware_detections:
            families = set()
            for d in spyware_detections:
                if d.threat_indicator:
                    families.add(d.threat_indicator.get_spyware_family_display())
            family_str = ', '.join(families) if families else 'sconosciuto'
            recs.append({
                'priority': 'critical',
                'action': 'factory_reset',
                'message': f'ATTENZIONE: Rilevati indicatori di spyware ({family_str}). '
                          f'Esegui IMMEDIATAMENTE un ripristino di fabbrica del dispositivo. '
                          f'Cambia tutte le password da un dispositivo sicuro. '
                          f'Contatta un esperto di sicurezza.',
            })

        if not recs:
            recs.append({
                'priority': 'info',
                'action': 'none',
                'message': 'Nessuna minaccia rilevata. Il tuo dispositivo è sicuro. '
                          'Continua a mantenere il sistema operativo aggiornato.',
            })

        return recs

    @classmethod
    def get_ioc_update(cls, platform, last_version=''):
        """
        Get IOC database update for a client device.
        Returns only new/updated IOCs since last_version.
        """
        current = IOCDatabaseVersion.objects.filter(is_current=True).first()
        if not current:
            return {'version': '0', 'indicators': [], 'has_update': False}

        if last_version == current.version:
            return {'version': current.version, 'indicators': [], 'has_update': False}

        # Get IOCs for this platform (one query, then count from list)
        base_qs = ThreatIndicator.objects.filter(
            is_active=True,
            platform__in=[platform, 'both', 'all'],
        )
        indicators_list = list(base_qs.values(
            'id', 'ioc_type', 'value', 'spyware_family',
            'severity', 'platform', 'description'
        ))

        return {
            'version': current.version,
            'has_update': True,
            'indicator_count': len(indicators_list),
            'indicators': indicators_list,
        }

    @classmethod
    def get_device_dashboard(cls, user):
        """Get security overview for all user's devices"""
        devices = DeviceSecurityProfile.objects.filter(user=user).order_by('-last_scan_at')

        result = []
        for device in devices:
            active_threats = ThreatDetection.objects.filter(
                device=device, status='detected'
            ).count()

            result.append({
                'device_id': device.device_id,
                'device_model': device.device_model,
                'os_type': device.os_type,
                'os_version': device.os_version,
                'risk_level': device.risk_level,
                'active_threats': active_threats,
                'last_scan': device.last_scan_at.isoformat() if device.last_scan_at else None,
                'scan_count': device.scan_count,
            })

        # Overall risk = highest risk across all devices
        risk_order = ['safe', 'low', 'medium', 'high', 'critical', 'compromised']
        overall_risk = 'safe'
        for d in result:
            if risk_order.index(d['risk_level']) > risk_order.index(overall_risk):
                overall_risk = d['risk_level']

        return {
            'overall_risk': overall_risk,
            'devices': result,
            'total_devices': len(result),
        }
