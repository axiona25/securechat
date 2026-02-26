from django.db import models
from django.conf import settings
from django.utils import timezone


class UserKeyBundle(models.Model):
    """Stores user's public keys for E2E encryption key exchange"""
    CRYPTO_VERSION_CHOICES = (
        (1, 'X448/Ed448 (legacy)'),
        (2, 'X25519/Ed25519 (production)'),
    )

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='key_bundle'
    )
    crypto_version = models.IntegerField(
        choices=CRYPTO_VERSION_CHOICES,
        default=2,
        help_text='1=X448/Ed448 (legacy), 2=X25519/Ed25519 (production)'
    )
    key_version = models.IntegerField(
        default=1,
        help_text='Incrementato ad ogni rotazione completa del bundle'
    )
    identity_key_public = models.BinaryField(
        help_text='Ed448 public key for identity verification (57 bytes)'
    )
    # We store a separate X448 identity key for DH operations
    identity_dh_public = models.BinaryField(
        help_text='X448 public key derived for DH identity operations (56 bytes)',
        null=True
    )
    signed_prekey_public = models.BinaryField(
        help_text='X448 signed prekey public (56 bytes)'
    )
    signed_prekey_signature = models.BinaryField(
        help_text='Ed448 signature over signed prekey'
    )
    signed_prekey_id = models.IntegerField(default=0)
    signed_prekey_created_at = models.DateTimeField(default=timezone.now)
    uploaded_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'user_key_bundles'

    def is_signed_prekey_stale(self):
        """Signed prekey should be rotated every 7 days"""
        return (timezone.now() - self.signed_prekey_created_at).days >= 7

    def __str__(self):
        return f'KeyBundle for {self.user.email}'


class OneTimePreKey(models.Model):
    """Ephemeral prekeys consumed during X3DH key exchange"""
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='one_time_prekeys'
    )
    key_id = models.IntegerField()
    public_key = models.BinaryField(help_text='X448 one-time prekey (56 bytes)')
    is_used = models.BooleanField(default=False)
    used_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='consumed_prekeys'
    )
    created_at = models.DateTimeField(auto_now_add=True)
    used_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = 'one_time_prekeys'
        unique_together = ['user', 'key_id']
        ordering = ['key_id']

    def __str__(self):
        return f'OTP#{self.key_id} user={self.user_id} used={self.is_used}'


class SessionKey(models.Model):
    """Encrypted Double Ratchet session state between two users"""
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='ratchet_sessions_owned'
    )
    peer = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='ratchet_sessions_peer'
    )
    session_data = models.BinaryField(help_text='Encrypted serialized ratchet state')
    session_version = models.IntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'session_keys'
        unique_together = ['user', 'peer']

    def __str__(self):
        return f'Session {self.user.email} <-> {self.peer.email}'


class KeyBundleFetchLog(models.Model):
    """Audit log for key bundle fetches - detect abuse/attacks"""
    requester = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='key_fetch_logs'
    )
    target_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='key_fetched_logs'
    )
    ip_address = models.GenericIPAddressField(null=True)
    user_agent = models.CharField(max_length=500, blank=True)
    fetched_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'key_bundle_fetch_logs'
        ordering = ['-fetched_at']

    def __str__(self):
        return f'{self.requester.email} fetched keys of {self.target_user.email} at {self.fetched_at}'


class SecurityAlert(models.Model):
    """Security alerts for suspicious activity"""
    ALERT_TYPES = [
        ('excessive_fetch', 'Excessive Key Bundle Fetches'),
        ('prekey_exhaustion', 'PreKey Pool Exhausted'),
        ('identity_change', 'Identity Key Changed'),
        ('multi_device_anomaly', 'Multiple Device Anomaly'),
        ('brute_force', 'Brute Force Attempt'),
    ]
    SEVERITY = [
        ('low', 'Low'),
        ('medium', 'Medium'),
        ('high', 'High'),
        ('critical', 'Critical'),
    ]
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='security_alerts'
    )
    alert_type = models.CharField(max_length=30, choices=ALERT_TYPES)
    severity = models.CharField(max_length=10, choices=SEVERITY, default='medium')
    message = models.TextField()
    metadata = models.JSONField(default=dict, blank=True)
    is_resolved = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    resolved_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = 'security_alerts'
        ordering = ['-created_at']

    def __str__(self):
        return f'[{self.severity}] {self.alert_type} for {self.user.email}'
