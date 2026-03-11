import logging
import os

logger = logging.getLogger(__name__)

# Cache dell'app Firebase Admin (può essere inizializzata da questo modulo o da altro, es. notifications)
_firebase_app = None


def _get_firebase_app():
    """Restituisce l'app Firebase Admin: riusa quella esistente o ne crea una sola volta."""
    global _firebase_app
    if _firebase_app is not None:
        return _firebase_app
    try:
        import firebase_admin
        from firebase_admin import credentials

        # Se la default app esiste già (inizializzata altrove), riusala
        try:
            _firebase_app = firebase_admin.get_app()
            logger.info('[PushBackend] firebase app reused')
            return _firebase_app
        except ValueError:
            pass  # nessuna app ancora, procediamo con initialize_app

        cred_path = os.environ.get('FIREBASE_CREDENTIALS_PATH', '/app/firebase-credentials.json')
        if os.path.exists(cred_path):
            cred = credentials.Certificate(cred_path)
            _firebase_app = firebase_admin.initialize_app(cred)
            logger.info('[PushBackend] firebase app initialized from credentials')
        else:
            _firebase_app = firebase_admin.initialize_app()
            logger.info('[PushBackend] firebase app initialized from default credentials')
        return _firebase_app
    except Exception as e:
        logger.error('[PushBackend] firebase init failed: %s', e)
        return None


def _get_chat_badge_count(user_id):
    """Get total unread messages count across all conversations for badge."""
    from chat.models import ConversationParticipant
    from django.db.models import Sum

    result = ConversationParticipant.objects.filter(
        user_id=user_id
    ).aggregate(total=Sum('unread_count'))
    return result['total'] or 0


# Chiavi FCM riservate: non usabili nel payload data (cf. FCM docs)
_FCM_RESERVED_KEYS = frozenset({'from', 'message_type'})
_FCM_RENAME = {'message_type': 'chat_message_type'}


def _sanitize_fcm_data(data):
    """
    Restituisce un dict con chiavi non riservate e valori stringa per FCM.
    Rinomina message_type -> chat_message_type; garantisce valori str.
    """
    if not data:
        return {}
    out = {}
    for k, v in data.items():
        if not isinstance(k, str) or k.startswith('google.') or k.startswith('gcm.'):
            continue
        key = _FCM_RENAME.get(k, k)
        if key in _FCM_RESERVED_KEYS:
            continue
        out[key] = str(v) if v is not None else ''
    return out


def send_push_notification(user, title, body, data=None):
    """Invia una notifica push a un utente specifico."""
    if not getattr(user, 'notifications_enabled', True):
        logger.info('[PushBackend] push skipped for user %s: notifications disabled', user.id)
        return False
    fcm_token = getattr(user, 'fcm_token', None)
    if not fcm_token:
        logger.info('[PushBackend] push skipped for user %s: no fcm token', user.id)
        return False

    try:
        from firebase_admin import messaging

        app = _get_firebase_app()
        if app is None:
            logger.warning('Firebase non inizializzato, skip notifica push')
            return False

        badge = _get_chat_badge_count(user.id)
        logger.info('[PushBackend] badge count = %s', badge)

        sanitized_data = _sanitize_fcm_data(data or {})
        logger.info('[PushBackend] sanitized data payload = %s', sanitized_data)

        message = messaging.Message(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data=sanitized_data,
            token=user.fcm_token,
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(
                        badge=badge,
                        sound='default',
                        content_available=True,
                    ),
                ),
            ),
        )
        response = messaging.send(message)
        logger.info('[PushBackend] firebase response = %s', response)
        logger.info('Push sent to %s: %s', user.username, response)
        return True
    except Exception as e:
        logger.error('Push notification error for %s: %s', user.username, e)
        # Token potrebbe essere scaduto
        if 'UNREGISTERED' in str(e) or 'INVALID' in str(e):
            user.fcm_token = None
            user.save(update_fields=['fcm_token'])
        return False


def send_android_incoming_call_data(user, call_data):
    """
    Invia messaggio FCM data-only ad alta priorità per chiamata in arrivo (Android).
    Il client Android mostrerà CallKit/Full Screen Intent.
    """
    if not getattr(user, 'fcm_token', None):
        return False
    try:
        from firebase_admin import messaging
        app = _get_firebase_app()
        if app is None:
            return False
        data_payload = {
            'type': 'incoming_call',
            'callId': str(call_data.get('call_id', '')),
            'callerName': call_data.get('caller_display_name', ''),
            'callType': call_data.get('call_type', 'audio'),
            'callerUserId': str(call_data.get('caller_user_id', '')),
            'conversationId': str(call_data.get('conversation_id', '')),
        }
        message = messaging.Message(
            data={k: str(v) for k, v in data_payload.items()},
            token=user.fcm_token,
            android=messaging.AndroidConfig(
                priority='high',
                data=data_payload,
            ),
            apns=messaging.APNSConfig(
                headers={'apns-push-type': 'voip', 'apns-priority': '10'},
                payload=messaging.APNSPayload(aps=messaging.Aps(content_available=True)),
            ),
        )
        messaging.send(message)
        logger.info('Android call data sent to user %s', user.id)
        return True
    except Exception as e:
        logger.exception('Android call data push error: %s', e)
        return False


def send_push_to_conversation_participants(conversation, sender, title, body, data=None):
    """Invia push a tutti i partecipanti di una conversazione tranne il mittente (con fcm_token)."""
    from chat.models import ConversationParticipant

    participants = ConversationParticipant.objects.filter(
        conversation=conversation
    ).exclude(user=sender).select_related('user')

    for participant in participants:
        user = participant.user
        logger.info(
            '[PushBackend] evaluating push for user %s (is_online=%s, conv=%s)',
            user.id,
            getattr(user, 'is_online', False),
            conversation.id,
        )
        logger.info('[PushBackend] sending chat push to user %s', user.id)
        send_push_notification(user, title, body, data)
