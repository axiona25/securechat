"""
Django signals for auto-creating notification preferences
and dispatching notifications from other apps.
"""
import logging
from django.db.models.signals import post_save
from django.dispatch import receiver
from django.conf import settings

from .models import NotificationPreference

logger = logging.getLogger(__name__)


@receiver(post_save, sender=settings.AUTH_USER_MODEL)
def create_notification_preferences(sender, instance, created, **kwargs):
    """Auto-create notification preferences when a new user is created."""
    if created:
        NotificationPreference.objects.get_or_create(user=instance)
        logger.debug(f'Created notification preferences for user {instance.username}')
