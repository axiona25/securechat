"""
APNs push notifications per messaggi chat.
Usa JWT token-based auth con .p8 key.
"""
import json
import logging
import os
import time

import jwt
import httpx
from django.db.models import Sum
from django.db.models import Sum

logger = logging.getLogger(__name__)

APNS_TOPIC = os.environ.get('APNS_TOPIC', 'com.axphone.app')
APNS_TEAM_ID = os.environ.get('APNS_TEAM_ID', 'F28CW3467A')
APNS_KEY_ID = os.environ.get('APNS_KEY_ID', '5GK4YZ6U3D')
APNS_AUTH_KEY_PATH = os.environ.get('APNS_AUTH_KEY_PATH', '/app/secrets/AuthKey_5GK4YZ6U3D.p8')
APNS_USE_SANDBOX = os.environ.get('APNS_USE_SANDBOX', 'false').lower() in ('true', '1', 'sandbox')

APNS_PRODUCTION = 'https://api.push.apple.com'
APNS_SANDBOX = 'https://api.sandbox.push.apple.com'

_cached_token = None
_cached_token_time = 0
_auth_key = None


def _load_auth_key():
    global _auth_key
    if _auth_key is None:
        with open(APNS_AUTH_KEY_PATH, 'r') as f:
            _auth_key = f.read()
    return _auth_key


def _get_jwt_token():
    global _cached_token, _cached_token_time
    now = int(time.time())
    if _cached_token and (now - _cached_token_time) < 3000:
        return _cached_token
    auth_key = _load_auth_key()
    _cached_token = jwt.encode(
        {'iss': APNS_TEAM_ID, 'iat': now},
        auth_key,
        algorithm='ES256',
        headers={'kid': APNS_KEY_ID}
    )
    _cached_token_time = now
    return _cached_token


def _get_badge_count(user):
    """Calcola il badge totale: somma unread_count di tutte le conversazioni."""
    try:
        from chat.models import ConversationParticipant
        total = ConversationParticipant.objects.filter(
            user=user, unread_count__gt=0
        ).aggregate(total=Sum("unread_count"))["total"] or 0
        return max(total, 1)  # Almeno 1 per il messaggio appena arrivato
    except Exception:
        return 1


def send_message_push(user, title, body, data=None):
    apns_token = getattr(user, 'apns_token', None)
    if not apns_token or not apns_token.strip():
        logger.debug('User %s has no apns_token, skip APNs push', user.id)
        return False

    token_hex = apns_token.strip().replace(' ', '').replace('<', '').replace('>', '')
    jwt_token = _get_jwt_token()

    use_sandbox = APNS_USE_SANDBOX
    base_url = APNS_SANDBOX if use_sandbox else APNS_PRODUCTION
    url = f'{base_url}/3/device/{token_hex}'

    # Calcola badge: totale messaggi non letti per questo utente
    badge_count = 1
    try:
        from chat.models import ConversationParticipant
        badge_count = ConversationParticipant.objects.filter(
            user=user, unread_count__gt=0
        ).aggregate(total=Sum('unread_count'))['total'] or 0
        if badge_count == 0:
            badge_count = 1  # Almeno 1 per il messaggio appena arrivato
    except Exception:
        badge_count = 1

    payload = {
        'aps': {
            'alert': {
                'title': title,
                'body': body,
            },
            'sound': 'default',
            'badge': badge_count,
            'mutable-content': 1,
        },
    }
    if data:
        payload.update(data)

    headers = {
        'authorization': f'bearer {jwt_token}',
        'apns-topic': APNS_TOPIC,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'content-type': 'application/json',
    }

    try:
        with httpx.Client(http2=True) as client:
            response = client.post(url, content=json.dumps(payload), headers=headers, timeout=10)
            if response.status_code == 400 and 'BadDeviceToken' in response.text:
                fallback_base = APNS_SANDBOX if not use_sandbox else APNS_PRODUCTION
                fallback_url = f'{fallback_base}/3/device/{token_hex}'
                logger.info('APNs push user=%s BadDeviceToken, trying fallback', user.id)
                response = client.post(fallback_url, content=json.dumps(payload), headers=headers, timeout=10)

        if response.status_code == 200:
            logger.info('APNs push OK user=%s title=%s', user.id, title)
            return True
        else:
            logger.warning('APNs push FAILED user=%s status=%s body=%s', user.id, response.status_code, response.text)
            return False
    except Exception as e:
        logger.exception('APNs push ERROR user=%s: %s', user.id, e)
        return False
