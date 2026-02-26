import logging
from celery import shared_task
from django.utils import timezone
from datetime import timedelta

logger = logging.getLogger(__name__)


@shared_task(
    name='notifications.deliver_push_notification',
    bind=True,
    max_retries=3,
    default_retry_delay=10,
)
def deliver_push_notification(self, notification_id, high_priority=False):
    """
    Celery task to deliver a single push notification via FCM.
    Retries with exponential backoff on temporary failures.
    """
    from .models import Notification
    from .fcm import send_push_notification

    try:
        notification = Notification.objects.get(id=notification_id)
    except Notification.DoesNotExist:
        logger.warning(f'Notification {notification_id} not found, skipping.')
        return

    try:
        success, failure = send_push_notification(notification, high_priority=high_priority)
        return {'success': success, 'failure': failure}
    except Exception as exc:
        logger.error(f'Error delivering notification {notification_id}: {exc}')
        # Retry with exponential backoff: 10s, 20s, 40s
        retry_delay = 10 * (2 ** self.request.retries)
        raise self.retry(exc=exc, countdown=retry_delay)


@shared_task(name='notifications.cleanup_old_notifications')
def cleanup_old_notifications(days=90):
    """
    Remove read notifications older than N days.
    Run daily via Celery Beat.
    """
    from .models import Notification

    cutoff = timezone.now() - timedelta(days=days)
    deleted_count, _ = Notification.objects.filter(
        is_read=True,
        created_at__lt=cutoff,
    ).delete()
    if deleted_count:
        logger.info(f'Cleaned up {deleted_count} old read notifications')
    return deleted_count


@shared_task(name='notifications.cleanup_expired_mute_rules')
def cleanup_expired_mute_rules():
    """
    Remove mute rules that have expired.
    Run hourly via Celery Beat.
    """
    from .models import MuteRule

    now = timezone.now()
    deleted_count, _ = MuteRule.objects.filter(
        muted_until__isnull=False,
        muted_until__lt=now,
    ).delete()
    if deleted_count:
        logger.info(f'Cleaned up {deleted_count} expired mute rules')
    return deleted_count


@shared_task(name='notifications.cleanup_stale_device_tokens')
def cleanup_stale_device_tokens(days=60):
    """
    Deactivate device tokens not used in N days.
    Run daily via Celery Beat.
    """
    from .models import DeviceToken

    cutoff = timezone.now() - timedelta(days=days)
    updated = DeviceToken.objects.filter(
        is_active=True,
        last_used_at__lt=cutoff,
    ).update(is_active=False)
    if updated:
        logger.info(f'Deactivated {updated} stale device tokens')
    return updated
