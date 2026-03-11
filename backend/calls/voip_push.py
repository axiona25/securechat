"""
VoIP Push Notifications via APNs for incoming calls (iOS background/standby).
Uses .p12 certificate and apns2 library.
"""
import logging
import os
import tempfile
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PrivateFormat,
    NoEncryption,
    pkcs12,
)

logger = logging.getLogger(__name__)

VOIP_TOPIC = 'com.axphone.app.voip'
CERT_PATH = os.environ.get('VOIP_CERT_PATH', '/app/config/voip_pushkit.p12')
CERT_PASSWORD = os.environ.get('VOIP_CERT_PASSWORD', '')


def _load_p12_credentials():
    """
    Load cert and key from .p12 into a single temporary PEM file (cert + key).
    apns2.CertificateCredentials(cert_file, password) expects one file; some
    backends accept .p12 path directly — if that fails we use combined PEM.
    """
    if not os.path.exists(CERT_PATH):
        logger.warning('VoIP cert not found: %s', CERT_PATH)
        return None, None
    try:
        with open(CERT_PATH, 'rb') as f:
            p12_data = f.read()
        password = CERT_PASSWORD.encode('utf-8') if CERT_PASSWORD else None
        key, cert, _ = pkcs12.load_key_and_certificates(p12_data, password)
        if key is None or cert is None:
            logger.warning('Could not extract key/cert from p12')
            return None, None
        cert_pem = cert.public_bytes(Encoding.PEM)
        key_pem = key.private_bytes(Encoding.PEM, PrivateFormat.TraditionalOpenSSL, NoEncryption())
        combined = tempfile.NamedTemporaryFile(mode='wb', suffix='.pem', delete=False)
        combined.write(cert_pem)
        combined.write(key_pem)
        combined.close()
        return combined.name, CERT_PASSWORD
    except Exception as e:
        logger.exception('Failed to load VoIP p12: %s', e)
        return None, None


def send_voip_push(user, call_data):
    """
    Send VoIP push via APNs to wake the app for an incoming call.
    user: callee User model instance (must have voip_token set).
    call_data: dict with caller_display_name, call_id, call_type, caller_user_id.
    """
    voip_token = getattr(user, 'voip_token', None)
    if not voip_token or not voip_token.strip():
        logger.debug('User %s has no voip_token, skip VoIP push', user.id)
        return False
    use_production = os.environ.get('DJANGO_ENV', '').lower() == 'production'
    try:
        from apns2.client import APNsClient
        from apns2.credentials import CertificateCredentials
    except ImportError as e:
        logger.warning('apns2 not available: %s', e)
        return False
    cert_path, key_path = _load_p12_credentials()
    if not cert_path or not key_path:
        return False
    caller_name = call_data.get('caller_display_name', '') or ''
    payload = {
        'aps': {},
        'handle': caller_name,
        'callerName': caller_name,
        'callId': str(call_data.get('call_id', '')),
        'callType': call_data.get('call_type', 'audio'),
        'callerUserId': str(call_data.get('caller_user_id', '')),
        'conversationId': str(call_data.get('conversation_id', '')),
    }
    try:
        cred = CertificateCredentials(cert_path, password=key_path)
        client = APNsClient(cred, use_sandbox=not use_production)
        from apns2.payload import Payload
        payload_obj = Payload(custom=payload)
        client.send_notification(voip_token, payload_obj, topic=VOIP_TOPIC)
        logger.info('VoIP push sent to user %s for call %s', user.id, call_data.get('call_id'))
        return True
    except Exception as e:
        logger.exception('VoIP push failed for user %s: %s', user.id, e)
        return False
    finally:
        try:
            if cert_path and os.path.exists(cert_path):
                os.unlink(cert_path)
        except OSError:
            pass
