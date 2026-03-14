"""
SecureChat - Push Notifications via server notify proprietario.
Questo file sostituisce completamente Firebase Cloud Messaging (FCM).
Tutte le notifiche vengono inviate tramite securechat_notify (FastAPI su porta 8002).
"""

import logging
from django.conf import settings

logger = logging.getLogger(__name__)


def send_push_notification(notification, high_priority=False):
    """
    Invia una notifica push tramite il server notify proprietario.

    Args:
        notification: Notification model instance
        high_priority: se True, usa priorità alta (per le chiamate)

    Returns:
        tuple: (success_count, failure_count)
    """
    from chat.push_notifications import send_push_notification as _send

    try:
        ok = _send(
            user_id=notification.recipient_id,
            title=notification.title,
            body=notification.body,
            data=notification.data or {},
            notification_type=notification.notification_type,
            sender_id=getattr(notification, 'sender_id', None),
        )
        if ok:
            notification.fcm_sent = True
            notification.save(update_fields=['fcm_sent'])
            logger.info(
                f"Notifica {notification.id} inviata tramite notify server "
                f"(type={notification.notification_type})"
            )
            return 1, 0
        else:
            notification.fcm_error = "Notify server returned False"
            notification.save(update_fields=['fcm_error'])
            logger.warning(f"Notifica {notification.id} non inviata dal notify server")
            return 0, 1
    except Exception as e:
        logger.exception(f"Errore invio notifica {notification.id}: {e}")
        notification.fcm_error = str(e)
        notification.save(update_fields=['fcm_error'])
        return 0, 1
