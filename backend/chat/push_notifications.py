import logging
import os

logger = logging.getLogger(__name__)

# Inizializza Firebase Admin SDK
_firebase_app = None


def _get_firebase_app():
    global _firebase_app
    if _firebase_app is not None:
        return _firebase_app
    try:
        import firebase_admin
        from firebase_admin import credentials

        cred_path = os.environ.get('FIREBASE_CREDENTIALS_PATH', '/app/firebase-credentials.json')
        if os.path.exists(cred_path):
            cred = credentials.Certificate(cred_path)
            _firebase_app = firebase_admin.initialize_app(cred)
        else:
            # Prova con le credenziali di default
            _firebase_app = firebase_admin.initialize_app()
        return _firebase_app
    except Exception as e:
        logger.error('Firebase init error: %s', e)
        return None


def _get_chat_badge_count(user_id):
    """Get total unread messages count across all conversations for badge."""
    from chat.models import ConversationParticipant
    from django.db.models import Sum

    result = ConversationParticipant.objects.filter(
        user_id=user_id
    ).aggregate(total=Sum('unread_count'))
    return result['total'] or 0


def send_push_notification(user, title, body, data=None):
    """Invia una notifica push a un utente specifico."""
    if not getattr(user, 'fcm_token', None):
        return False

    try:
        from firebase_admin import messaging

        app = _get_firebase_app()
        if app is None:
            logger.warning('Firebase non inizializzato, skip notifica push')
            return False

        message = messaging.Message(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data=data or {},
            token=user.fcm_token,
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(
                        badge=_get_chat_badge_count(user.id),
                        sound='default',
                        content_available=True,
                    ),
                ),
            ),
        )
        response = messaging.send(message)
        logger.info('Push sent to %s: %s', user.username, response)
        return True
    except Exception as e:
        logger.error('Push notification error for %s: %s', user.username, e)
        # Token potrebbe essere scaduto
        if 'UNREGISTERED' in str(e) or 'INVALID' in str(e):
            user.fcm_token = None
            user.save(update_fields=['fcm_token'])
        return False


def send_push_to_conversation_participants(conversation, sender, title, body, data=None):
    """Invia push a tutti i partecipanti di una conversazione tranne il mittente."""
    from chat.models import ConversationParticipant

    participants = ConversationParticipant.objects.filter(
        conversation=conversation
    ).exclude(user=sender).select_related('user')

    for participant in participants:
        user = participant.user
        # Non inviare se l'utente è online (sta guardando la chat)
        if not getattr(user, 'is_online', False):
            send_push_notification(user, title, body, data)
