"""
Serializers for encryption app. Backup payload is opaque to the server (client-encrypted blob).
"""
import base64
from rest_framework import serializers
from .models import E2EKeyBackup


# Max backup payload size (ciphertext + salt + nonce) — 256 KB
E2E_BACKUP_MAX_BYTES = 256 * 1024


class E2EKeyBackupSerializer(serializers.ModelSerializer):
    """Read/write backup blob; binary fields as base64 in JSON."""
    salt = serializers.CharField(write_only=True)
    nonce = serializers.CharField(write_only=True)
    ciphertext = serializers.CharField(write_only=True)

    class Meta:
        model = E2EKeyBackup
        fields = (
            'version',
            'kdf_algorithm',
            'kdf_params',
            'salt',
            'nonce',
            'ciphertext',
            'created_at',
            'updated_at',
        )
        read_only_fields = ('created_at', 'updated_at')

    def validate_salt(self, value):
        try:
            raw = base64.b64decode(value, validate=True)
        except Exception as e:
            raise serializers.ValidationError(f'Invalid base64 salt: {e}')
        if len(raw) > 256:
            raise serializers.ValidationError('Salt too long.')
        return raw

    def validate_nonce(self, value):
        try:
            raw = base64.b64decode(value, validate=True)
        except Exception as e:
            raise serializers.ValidationError(f'Invalid base64 nonce: {e}')
        if len(raw) > 256:
            raise serializers.ValidationError('Nonce too long.')
        return raw

    def validate_ciphertext(self, value):
        try:
            raw = base64.b64decode(value, validate=True)
        except Exception as e:
            raise serializers.ValidationError(f'Invalid base64 ciphertext: {e}')
        if len(raw) > E2E_BACKUP_MAX_BYTES:
            raise serializers.ValidationError(
                f'Ciphertext exceeds max size ({E2E_BACKUP_MAX_BYTES} bytes).'
            )
        return raw

    def validate_kdf_params(self, value):
        if not isinstance(value, dict):
            raise serializers.ValidationError('kdf_params must be a JSON object.')
        return value

    def to_representation(self, instance):
        """Return backup for GET: binary fields as base64."""
        return {
            'version': instance.version,
            'kdf_algorithm': instance.kdf_algorithm,
            'kdf_params': instance.kdf_params,
            'salt': base64.b64encode(instance.salt).decode('ascii'),
            'nonce': base64.b64encode(instance.nonce).decode('ascii'),
            'ciphertext': base64.b64encode(instance.ciphertext).decode('ascii'),
            'created_at': instance.created_at,
            'updated_at': instance.updated_at,
        }
