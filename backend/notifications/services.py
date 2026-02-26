import logging
import hashlib
from django.conf import settings
from django.utils import timezone
from django.core.cache import cache
from .models import (
    DeviceToken, NotificationPreference, MuteRule,
    Notification, NotificationType,
)

logger = logging.getLogger(__name__)

# Throttle window in seconds
THROTTLE_WINDOW = 30


class NotificationService:
    """
    Central service for creating and sending push notifications.
    All notification logic flows through this class.
    """

    @classmethod
    def send(
        cls,
        recipient_id,
        notification_type,
        title,
        body,
        data=None,
        sender_id=None,
        source_type='',
        source_id='',
        target_type=None,
        target_id=None,
        high_priority=False,
    ):
        """
        Main entry point to send a notification.
        This method checks preferences, mute rules, DND, throttling,
        creates the DB record, and dispatches the Celery task for FCM delivery.

        Args:
            recipient_id: ID of the user to notify
            notification_type: one of NotificationType choices
            title: notification title
            body: notification body text
            data: dict of extra payload
            sender_id: ID of the user who triggered the notification (optional)
            source_type: type of source object (e.g. 'message', 'call')
            source_id: UUID string of source object
            target_type: for mute check ('conversation', 'group', 'channel')
            target_id: UUID string for mute check
            high_priority: skip DND/throttle (e.g. incoming calls, security alerts)
        """
        if data is None:
            data = {}

        # 1. Don't notify yourself
        if sender_id and str(sender_id) == str(recipient_id):
            return None

        # 2. Check user preferences
        prefs = cls._get_preferences(recipient_id)

        if not prefs.is_type_enabled(notification_type):
            logger.debug(f'Notification {notification_type} disabled for user {recipient_id}')
            return None

        # 3. Check DND (skip for high priority)
        if not high_priority and prefs.is_in_dnd():
            logger.debug(f'User {recipient_id} is in DND mode')
            return None

        # 4. Check mute rules
        if target_type and target_id:
            if cls._is_muted(recipient_id, target_type, target_id):
                logger.debug(f'Target {target_type}:{target_id} is muted for user {recipient_id}')
                return None

        # 5. Throttle check (skip for high priority)
        if not high_priority:
            throttle_key = cls._throttle_key(recipient_id, notification_type, source_type, source_id)
            if cache.get(throttle_key):
                logger.debug(f'Throttled notification {notification_type} for user {recipient_id}')
                return None
            cache.set(throttle_key, 1, THROTTLE_WINDOW)

        # 6. Add preview setting to data
        data['show_preview'] = prefs.show_preview
        data['sound_enabled'] = prefs.sound_enabled
        data['vibration_enabled'] = prefs.vibration_enabled

        # 7. Create notification record
        notification = Notification.objects.create(
            recipient_id=recipient_id,
            sender_id=sender_id,
            notification_type=notification_type,
            title=title,
            body=body,
            data=data,
            source_type=source_type,
            source_id=str(source_id) if source_id else '',
        )

        # 8. Dispatch Celery task for FCM delivery
        from .tasks import deliver_push_notification
        deliver_push_notification.delay(
            str(notification.id),
            high_priority=high_priority,
        )

        return notification

    @classmethod
    def send_to_multiple(
        cls,
        recipient_ids,
        notification_type,
        title,
        body,
        data=None,
        sender_id=None,
        source_type='',
        source_id='',
        target_type=None,
        target_id=None,
        high_priority=False,
    ):
        """Send the same notification to multiple recipients."""
        results = []
        for rid in recipient_ids:
            result = cls.send(
                recipient_id=rid,
                notification_type=notification_type,
                title=title,
                body=body,
                data=data.copy() if data else {},
                sender_id=sender_id,
                source_type=source_type,
                source_id=source_id,
                target_type=target_type,
                target_id=target_id,
                high_priority=high_priority,
            )
            if result:
                results.append(result)
        return results

    @classmethod
    def _get_preferences(cls, user_id):
        """Get or create notification preferences for a user."""
        prefs, _ = NotificationPreference.objects.get_or_create(user_id=user_id)
        return prefs

    @classmethod
    def _is_muted(cls, user_id, target_type, target_id):
        """Check if the target is muted for this user."""
        rule = MuteRule.objects.filter(
            user_id=user_id,
            target_type=target_type,
            target_id=str(target_id),
        ).first()
        if rule is None:
            return False
        return rule.is_active

    @classmethod
    def _throttle_key(cls, recipient_id, notification_type, source_type, source_id):
        """Generate a cache key for throttling."""
        raw = f'notif_throttle:{recipient_id}:{notification_type}:{source_type}:{source_id}'
        return hashlib.md5(raw.encode()).hexdigest()

    @classmethod
    def get_badge_count(cls, user_id):
        """Get unread notification count and breakdown by type."""
        from django.db.models import Count
        qs = Notification.objects.filter(recipient_id=user_id, is_read=False)
        total = qs.count()
        by_type = dict(
            qs.values('notification_type')
            .annotate(count=Count('id'))
            .values_list('notification_type', 'count')
        )
        return {'unread_count': total, 'by_type': by_type}
