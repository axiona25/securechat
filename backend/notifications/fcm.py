"""
Firebase Cloud Messaging integration.
Handles actual sending of push notifications via FCM v1 API.
"""
import logging
from django.conf import settings
from .models import DeviceToken

logger = logging.getLogger(__name__)


def send_push_notification(notification, high_priority=False):
    """
    Send a push notification to all active devices of the recipient.

    Args:
        notification: Notification model instance
        high_priority: if True, use high priority (for calls)

    Returns:
        tuple: (success_count, failure_count)
    """
    if not getattr(settings, 'FIREBASE_ENABLED', False):
        logger.warning('Firebase is not enabled. Skipping push notification.')
        return 0, 0

    from firebase_admin import messaging

    tokens = list(
        DeviceToken.objects.filter(
            user_id=notification.recipient_id,
            is_active=True,
        ).values_list('token', flat=True)
    )

    if not tokens:
        logger.debug(f'No active tokens for user {notification.recipient_id}')
        return 0, 0

    # Build the FCM message
    is_data_only = notification.notification_type == 'incoming_call'

    # Data payload (always present) — FCM requires string values
    data_payload = {
        'notification_id': str(notification.id),
        'type': notification.notification_type,
        'source_type': notification.source_type,
        'source_id': notification.source_id,
    }
    if notification.data:
        for key, value in notification.data.items():
            data_payload[key] = str(value)

    # Android config
    android_notification = None
    if not is_data_only:
        android_notification = messaging.AndroidNotification(
            title=notification.title,
            body=notification.body,
            click_action='FLUTTER_NOTIFICATION_CLICK',
            sound='default' if notification.data.get('sound_enabled', True) else None,
            channel_id=_get_android_channel(notification.notification_type),
        )
    android_config = messaging.AndroidConfig(
        priority='high' if high_priority else 'normal',
        ttl=0 if notification.notification_type == 'incoming_call' else 86400,
        notification=android_notification,
    )

    # APNs config
    apns_headers = {
        'apns-priority': '10' if high_priority else '5',
    }
    if notification.notification_type == 'incoming_call':
        apns_headers['apns-push-type'] = 'voip'
        apns_headers['apns-topic'] = f'{getattr(settings, "IOS_BUNDLE_ID", "com.securechat.app")}.voip'
    else:
        apns_headers['apns-push-type'] = 'alert'

    badge = _get_badge_count(notification.recipient_id)
    aps_alert = None
    if not is_data_only:
        aps_alert = messaging.ApsAlert(
            title=notification.title,
            body=notification.body,
        )
    apns_aps = messaging.Aps(
        alert=aps_alert,
        sound='default' if (not is_data_only and notification.data.get('sound_enabled', True)) else None,
        badge=badge,
        content_available=is_data_only,
        mutable_content=not is_data_only,
    )
    apns_config = messaging.APNSConfig(
        headers=apns_headers,
        payload=messaging.APNSPayload(aps=apns_aps),
    )

    # Web push config
    web_config = None
    if not is_data_only:
        web_config = messaging.WebpushConfig(
            notification=messaging.WebpushNotification(
                title=notification.title,
                body=notification.body,
                icon='/static/icons/notification-icon.png',
            ),
        )

    success_count = 0
    failure_count = 0
    invalid_tokens = []

    # Send in batches of 500 (FCM multicast limit)
    for i in range(0, len(tokens), 500):
        batch_tokens = tokens[i:i + 500]

        multicast_message = messaging.MulticastMessage(
            tokens=batch_tokens,
            data=data_payload,
            android=android_config,
            apns=apns_config,
            webpush=web_config,
        )

        try:
            response = messaging.send_each_for_multicast(multicast_message)
            success_count += response.success_count
            failure_count += response.failure_count

            # Process individual responses to find invalid tokens
            for idx, send_response in enumerate(response.responses):
                if send_response.exception:
                    error_code = _get_error_code(send_response.exception)
                    if error_code in (
                        'NOT_FOUND',
                        'UNREGISTERED',
                        'INVALID_ARGUMENT',
                    ):
                        invalid_tokens.append(batch_tokens[idx])
                    logger.warning(
                        f'FCM error for token {batch_tokens[idx][:20]}...: '
                        f'{error_code} — {send_response.exception}'
                    )
                else:
                    if send_response.message_id and not notification.fcm_message_id:
                        notification.fcm_message_id = send_response.message_id

        except Exception as e:
            logger.error(f'FCM multicast send error: {e}')
            failure_count += len(batch_tokens)
            notification.fcm_error = str(e)

    # Deactivate invalid tokens
    if invalid_tokens:
        deactivated = DeviceToken.objects.filter(
            token__in=invalid_tokens
        ).update(is_active=False)
        logger.info(f'Deactivated {deactivated} invalid FCM tokens')

    # Update notification delivery status
    notification.fcm_sent = success_count > 0
    if not notification.fcm_error and failure_count > 0 and success_count == 0:
        notification.fcm_error = f'All {failure_count} deliveries failed'
    notification.save(update_fields=['fcm_sent', 'fcm_message_id', 'fcm_error'])

    logger.info(
        f'Push notification {notification.id}: '
        f'{success_count} sent, {failure_count} failed '
        f'(type={notification.notification_type})'
    )

    return success_count, failure_count


def _get_android_channel(notification_type):
    """Map notification type to Android notification channel."""
    channel_map = {
        'new_message': 'messages',
        'message_reaction': 'reactions',
        'mention': 'mentions',
        'incoming_call': 'calls',
        'missed_call': 'calls',
        'channel_post': 'channels',
        'group_invite': 'invites',
        'channel_invite': 'invites',
        'security_alert': 'security',
    }
    return channel_map.get(notification_type, 'default')


def _get_badge_count(user_id):
    """Get current unread notification count for badge."""
    from .models import Notification
    return Notification.objects.filter(
        recipient_id=user_id, is_read=False
    ).count()


def _get_error_code(exception):
    """Extract error code from Firebase exception."""
    if hasattr(exception, 'code'):
        return getattr(exception, 'code', str(exception))
    error_str = str(exception).upper()
    for code in ('NOT_FOUND', 'UNREGISTERED', 'INVALID_ARGUMENT', 'UNAVAILABLE', 'INTERNAL'):
        if code in error_str:
            return code
    return 'UNKNOWN'
