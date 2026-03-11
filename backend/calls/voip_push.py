"""
VoIP Push Notifications via APNs for incoming calls (iOS background/standby).
Uses .p12 certificate and httpx with HTTP/2 (Python 3.12 compatible).
"""
import json
import logging
import os
import tempfile
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PrivateFormat,
    NoEncryption,
)
from cryptography.hazmat.primitives.serialization.pkcs12 import load_key_and_certificates

logger = logging.getLogger(__name__)

VOIP_TOPIC = 'com.axphone.app.voip'
CERT_PATH = os.environ.get('VOIP_CERT_PATH', '/app/config/voip_pushkit.p12')
CERT_PASSWORD = os.environ.get('VOIP_CERT_PASSWORD', '')

APNS_PRODUCTION = 'https://api.push.apple.com'
APNS_SANDBOX = 'https://api.sandbox.push.apple.com'


def _load_p12_credentials():
    """
    Load cert and key from .p12 into temporary PEM files.
    Returns (cert_pem_path, key_pem_path) or (None, None).
    """
    if not os.path.exists(CERT_PATH):
        logger.warning('VoIP cert not found: %s', CERT_PATH)
        return None, None
    try:
        with open(CERT_PATH, 'rb') as f:
            p12_data = f.read()
        password = CERT_PASSWORD.encode('utf-8') if CERT_PASSWORD else None
        key, cert, _ = load_key_and_certificates(p12_data, password)
        if key is None or cert is None:
            logger.warning('Could not extract key/cert from p12')
            return None, None
        cert_pem = cert.public_bytes(Encoding.PEM)
        key_pem = key.private_bytes(
            Encoding.PEM, PrivateFormat.TraditionalOpenSSL, NoEncryption()
        )
        cert_file = tempfile.NamedTemporaryFile(
            mode='wb', suffix='.pem', delete=False
        )
        key_file = tempfile.NamedTemporaryFile(
            mode='wb', suffix='.pem', delete=False
        )
        cert_file.write(cert_pem)
        key_file.write(key_pem)
        cert_file.close()
        key_file.close()
        return cert_file.name, key_file.name
    except Exception as e:
        logger.exception('Failed to load VoIP p12: %s', e)
        return None, None


def send_voip_push(user, call_data):
    """
    Send VoIP push via APNs to wake the app for an incoming call.
    user: callee User model instance (must have voip_token set).
    call_data: dict with caller_display_name, call_id, call_type, caller_user_id, conversation_id.
    """
    voip_token = getattr(user, 'voip_token', None)
    if not voip_token or not voip_token.strip():
        logger.debug('User %s has no voip_token, skip VoIP push', user.id)
        return False

    use_production = os.environ.get('DJANGO_ENV', '').lower() == 'production'
    base_url = APNS_PRODUCTION if use_production else APNS_SANDBOX
    url = f'{base_url}/3/device/{voip_token.strip()}'

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
        import httpx
        with httpx.Client(
            cert=(cert_path, key_path),
            http2=True,
        ) as client:
            response = client.post(
                url,
                headers={
                    'apns-topic': VOIP_TOPIC,
                    'apns-push-type': 'voip',
                    'apns-priority': '10',
                    'content-type': 'application/json',
                },
                content=json.dumps(payload),
            )
            logger.info(
                'VoIP push to user %s for call %s: status=%s body=%s',
                user.id,
                call_data.get('call_id'),
                response.status_code,
                response.text,
            )
            if response.status_code in (200, 201):
                return True
            logger.warning(
                'VoIP push rejected: status=%s body=%s',
                response.status_code,
                response.text,
            )
            return False
    except Exception as e:
        logger.exception('VoIP push failed for user %s: %s', user.id, e)
        return False
    finally:
        try:
            if cert_path and os.path.exists(cert_path):
                os.unlink(cert_path)
            if key_path and os.path.exists(key_path):
                os.unlink(key_path)
        except OSError as e:
            logger.debug('Cleanup temp PEM files: %s', e)
