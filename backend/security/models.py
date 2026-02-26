import uuid
from django.db import models
from django.conf import settings
from django.utils import timezone


class ThreatIndicator(models.Model):
    """
    Indicators of Compromise (IOC) database.
    Updated from Amnesty International MVT, Google TAG, Citizen Lab, 
    and internal research. Distributed to all clients for local scanning.
    """
    IOC_TYPES = [
        ('domain', 'Malicious Domain'),
        ('ip', 'Malicious IP Address'),
        ('process', 'Suspicious Process Name'),
        ('file_path', 'Suspicious File Path'),
        ('file_hash', 'Malicious File Hash'),
        ('certificate', 'Suspicious SSL Certificate'),
        ('package', 'Malicious Package/App'),
        ('behavior', 'Behavioral Pattern'),
        ('network_pattern', 'Network Traffic Pattern'),
        ('dns', 'Suspicious DNS Query'),
    ]
    SPYWARE_FAMILIES = [
        ('pegasus', 'NSO Group Pegasus'),
        ('predator', 'Cytrox/Intellexa Predator'),
        ('hermit', 'RCS Lab Hermit'),
        ('candiru', 'Candiru DevilsTongue'),
        ('finspy', 'FinFisher FinSpy'),
        ('quadream', 'QuaDream Reign'),
        ('cytrox', 'Cytrox'),
        ('unknown', 'Unknown/Generic'),
        ('custom', 'Custom/Research'),
    ]
    SEVERITY_LEVELS = [
        (1, 'Informational'),
        (2, 'Low'),
        (3, 'Medium'),
        (4, 'High'),
        (5, 'Critical - Confirmed Spyware'),
    ]
    PLATFORMS = [
        ('ios', 'iOS'),
        ('android', 'Android'),
        ('both', 'iOS & Android'),
        ('windows', 'Windows'),
        ('macos', 'macOS'),
        ('all', 'All Platforms'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    ioc_type = models.CharField(max_length=20, choices=IOC_TYPES)
    value = models.TextField(help_text='The actual IOC value (domain, IP, hash, path, etc.)')
    spyware_family = models.CharField(max_length=20, choices=SPYWARE_FAMILIES, default='unknown')
    severity = models.IntegerField(choices=SEVERITY_LEVELS, default=3)
    platform = models.CharField(max_length=10, choices=PLATFORMS, default='both')
    description = models.TextField(blank=True, default='')
    source = models.CharField(
        max_length=200, blank=True, default='',
        help_text='Where this IOC came from (e.g., Amnesty MVT, Citizen Lab, internal)'
    )
    first_seen = models.DateTimeField(null=True, blank=True)
    last_seen = models.DateTimeField(null=True, blank=True)
    is_active = models.BooleanField(default=True)
    false_positive_count = models.IntegerField(default=0)
    true_positive_count = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'threat_indicators'
        ordering = ['-severity', '-updated_at']
        indexes = [
            models.Index(fields=['ioc_type', 'is_active']),
            models.Index(fields=['spyware_family']),
            models.Index(fields=['platform']),
        ]

    def __str__(self):
        return f'[{self.get_severity_display()}] {self.ioc_type}: {self.value[:50]} ({self.spyware_family})'


class DeviceSecurityProfile(models.Model):
    """
    Security profile for each user device.
    Tracks the device's security posture over time.
    """
    RISK_LEVELS = [
        ('safe', 'Safe'),
        ('low', 'Low Risk'),
        ('medium', 'Medium Risk'),
        ('high', 'High Risk'),
        ('critical', 'Critical - Possible Compromise'),
        ('compromised', 'Confirmed Compromise'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='device_profiles'
    )
    device_id = models.CharField(max_length=200, help_text='Unique device identifier')
    device_model = models.CharField(max_length=100, blank=True, default='')
    os_type = models.CharField(max_length=10, choices=[('ios','iOS'),('android','Android'),('desktop','Desktop')])
    os_version = models.CharField(max_length=50, blank=True, default='')
    app_version = models.CharField(max_length=20, blank=True, default='')
    # Security status
    risk_level = models.CharField(max_length=15, choices=RISK_LEVELS, default='safe')
    is_rooted = models.BooleanField(default=False)
    is_debugger_attached = models.BooleanField(default=False)
    has_hooking_frameworks = models.BooleanField(default=False)
    has_suspicious_apps = models.BooleanField(default=False)
    has_network_anomalies = models.BooleanField(default=False)
    code_integrity_valid = models.BooleanField(default=True)
    certificate_pinning_valid = models.BooleanField(default=True)
    secure_enclave_available = models.BooleanField(default=True)
    # Tracking
    last_scan_at = models.DateTimeField(null=True, blank=True)
    last_ioc_version = models.CharField(
        max_length=50, blank=True, default='',
        help_text='Last IOC database version synced'
    )
    scan_count = models.IntegerField(default=0)
    threat_count = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'device_security_profiles'
        unique_together = ['user', 'device_id']

    def __str__(self):
        return f'{self.user.email} - {self.device_model} ({self.risk_level})'


class ThreatDetection(models.Model):
    """
    Log of threats detected on user devices.
    Each entry represents a specific threat found during a scan.
    """
    DETECTION_STATUS = [
        ('detected', 'Detected'),
        ('investigating', 'Under Investigation'),
        ('confirmed', 'Confirmed Threat'),
        ('false_positive', 'False Positive'),
        ('resolved', 'Resolved'),
        ('ignored', 'Ignored by User'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    device = models.ForeignKey(
        DeviceSecurityProfile,
        on_delete=models.CASCADE,
        related_name='detections'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='threat_detections'
    )
    threat_indicator = models.ForeignKey(
        ThreatIndicator,
        null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='detections'
    )
    detection_type = models.CharField(max_length=50)
    detection_detail = models.TextField(help_text='What exactly was found')
    matched_value = models.TextField(blank=True, default='', help_text='The value that matched the IOC')
    severity = models.IntegerField(default=3)
    status = models.CharField(max_length=15, choices=DETECTION_STATUS, default='detected')
    # Context
    scan_type = models.CharField(
        max_length=20,
        choices=[
            ('startup', 'App Startup Scan'),
            ('periodic', 'Periodic Scan'),
            ('manual', 'User-Initiated Scan'),
            ('realtime', 'Real-Time Detection'),
            ('network', 'Network Monitoring'),
        ],
        default='periodic'
    )
    raw_evidence = models.JSONField(
        default=dict, blank=True,
        help_text='Raw data supporting the detection'
    )
    # Timestamps
    detected_at = models.DateTimeField(auto_now_add=True)
    resolved_at = models.DateTimeField(null=True, blank=True)
    user_notified = models.BooleanField(default=False)
    user_notified_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = 'threat_detections'
        ordering = ['-detected_at']

    def __str__(self):
        return f'[{self.severity}] {self.detection_type} on {self.device} ({self.status})'


class NetworkAnomalyLog(models.Model):
    """
    Log of suspicious network connections detected by clients.
    Used for centralized analysis and IOC enrichment.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    device = models.ForeignKey(
        DeviceSecurityProfile,
        on_delete=models.CASCADE,
        related_name='network_anomalies'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='network_anomalies'
    )
    destination_ip = models.GenericIPAddressField(null=True, blank=True)
    destination_domain = models.CharField(max_length=300, blank=True, default='')
    destination_port = models.IntegerField(null=True, blank=True)
    protocol = models.CharField(max_length=10, default='tcp')
    bytes_sent = models.BigIntegerField(default=0)
    bytes_received = models.BigIntegerField(default=0)
    connection_duration = models.FloatField(null=True, blank=True, help_text='Duration in seconds')
    is_suspicious = models.BooleanField(default=False)
    suspicion_reason = models.TextField(blank=True, default='')
    matched_ioc = models.ForeignKey(
        ThreatIndicator,
        null=True, blank=True,
        on_delete=models.SET_NULL
    )
    detected_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'network_anomaly_logs'
        ordering = ['-detected_at']

    def __str__(self):
        return f'{self.destination_domain or self.destination_ip}:{self.destination_port} ({self.suspicion_reason[:50]})'


class IOCDatabaseVersion(models.Model):
    """
    Versioning for the IOC database distributed to clients.
    Each update generates a new version that clients sync.
    """
    version = models.CharField(max_length=50, unique=True)
    ioc_count = models.IntegerField(default=0)
    changelog = models.TextField(blank=True, default='')
    published_at = models.DateTimeField(auto_now_add=True)
    is_current = models.BooleanField(default=False)

    class Meta:
        db_table = 'ioc_database_versions'
        ordering = ['-published_at']

    def __str__(self):
        return f'IOC v{self.version} ({self.ioc_count} indicators)'

    def save(self, *args, **kwargs):
        if self.is_current:
            IOCDatabaseVersion.objects.filter(is_current=True).update(is_current=False)
        super().save(*args, **kwargs)
