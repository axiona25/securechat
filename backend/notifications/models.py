import uuid
from django.db import models
from django.conf import settings
from django.utils import timezone


class DeviceToken(models.Model):
    class Platform(models.TextChoices):
        ANDROID = 'android', 'Android'
        IOS = 'ios', 'iOS'
        WEB = 'web', 'Web'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='device_tokens'
    )
    token = models.CharField(max_length=500, db_index=True)
    platform = models.CharField(
        max_length=10,
        choices=Platform.choices,
    )
    device_id = models.CharField(max_length=255, help_text='Unique device identifier')
    device_name = models.CharField(max_length=255, blank=True, default='')
    is_active = models.BooleanField(default=True)
    last_used_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'notification_device_tokens'
        unique_together = ('user', 'device_id')
        indexes = [
            models.Index(fields=['user', 'is_active']),
        ]

    def __str__(self):
        return f'{self.user.username} — {self.platform} ({self.device_id[:20]})'


class NotificationType(models.TextChoices):
    NEW_MESSAGE = 'new_message', 'New Message'
    MESSAGE_REACTION = 'message_reaction', 'Message Reaction'
    MENTION = 'mention', 'Mention'
    INCOMING_CALL = 'incoming_call', 'Incoming Call'
    MISSED_CALL = 'missed_call', 'Missed Call'
    CHANNEL_POST = 'channel_post', 'Channel Post'
    GROUP_INVITE = 'group_invite', 'Group Invite'
    CHANNEL_INVITE = 'channel_invite', 'Channel Invite'
    SECURITY_ALERT = 'security_alert', 'Security Alert'


class NotificationPreference(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='notification_preferences'
    )

    # Per-type toggles
    new_message = models.BooleanField(default=True)
    message_reaction = models.BooleanField(default=True)
    mention = models.BooleanField(default=True)
    incoming_call = models.BooleanField(default=True)
    missed_call = models.BooleanField(default=True)
    channel_post = models.BooleanField(default=True)
    group_invite = models.BooleanField(default=True)
    channel_invite = models.BooleanField(default=True)
    security_alert = models.BooleanField(default=True)

    # Do Not Disturb
    dnd_enabled = models.BooleanField(default=False)
    dnd_start_time = models.TimeField(null=True, blank=True, help_text='DND start (local time)')
    dnd_end_time = models.TimeField(null=True, blank=True, help_text='DND end (local time)')

    # Sound/Vibration
    sound_enabled = models.BooleanField(default=True)
    vibration_enabled = models.BooleanField(default=True)

    # Preview
    show_preview = models.BooleanField(default=True, help_text='Show message content in notification')

    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'notification_preferences'

    def __str__(self):
        return f'Preferences for {self.user.username}'

    def is_type_enabled(self, notification_type):
        """Check if a specific notification type is enabled."""
        field_map = {
            NotificationType.NEW_MESSAGE: self.new_message,
            NotificationType.MESSAGE_REACTION: self.message_reaction,
            NotificationType.MENTION: self.mention,
            NotificationType.INCOMING_CALL: self.incoming_call,
            NotificationType.MISSED_CALL: self.missed_call,
            NotificationType.CHANNEL_POST: self.channel_post,
            NotificationType.GROUP_INVITE: self.group_invite,
            NotificationType.CHANNEL_INVITE: self.channel_invite,
            NotificationType.SECURITY_ALERT: self.security_alert,
        }
        return field_map.get(notification_type, True)

    def is_in_dnd(self, current_time=None):
        """Check if user is currently in Do Not Disturb mode."""
        if not self.dnd_enabled:
            return False
        if not self.dnd_start_time or not self.dnd_end_time:
            return self.dnd_enabled  # DND always on if no times set
        if current_time is None:
            current_time = timezone.localtime().time()
        if self.dnd_start_time <= self.dnd_end_time:
            return self.dnd_start_time <= current_time <= self.dnd_end_time
        else:
            # Wraps midnight (e.g., 22:00 - 07:00)
            return current_time >= self.dnd_start_time or current_time <= self.dnd_end_time


class MuteRule(models.Model):
    """Mute notifications for a specific conversation, group, or channel."""
    class TargetType(models.TextChoices):
        CONVERSATION = 'conversation', 'Conversation'
        GROUP = 'group', 'Group'
        CHANNEL = 'channel', 'Channel'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='mute_rules'
    )
    target_type = models.CharField(max_length=15, choices=TargetType.choices)
    target_id = models.CharField(max_length=36, help_text='UUID of conversation, group, or channel')
    muted_until = models.DateTimeField(
        null=True, blank=True,
        help_text='Null = muted forever, datetime = muted until'
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'notification_mute_rules'
        unique_together = ('user', 'target_type', 'target_id')
        indexes = [
            models.Index(fields=['user', 'target_type', 'target_id']),
        ]

    def __str__(self):
        return f'{self.user.username} muted {self.target_type}:{self.target_id}'

    @property
    def is_active(self):
        if self.muted_until is None:
            return True
        return timezone.now() < self.muted_until


class Notification(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    recipient = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='notifications'
    )
    sender = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='sent_notifications'
    )
    notification_type = models.CharField(
        max_length=20,
        choices=NotificationType.choices,
    )
    title = models.CharField(max_length=255)
    body = models.TextField(max_length=1000)
    data = models.JSONField(default=dict, blank=True, help_text='Extra payload sent to client')

    # Reference to source object
    source_type = models.CharField(max_length=50, blank=True, default='', help_text='e.g. message, call, channel_post')
    source_id = models.CharField(max_length=36, blank=True, default='', help_text='UUID of source object')

    is_read = models.BooleanField(default=False)
    read_at = models.DateTimeField(null=True, blank=True)

    # FCM delivery status
    fcm_sent = models.BooleanField(default=False)
    fcm_message_id = models.CharField(max_length=255, blank=True, default='')
    fcm_error = models.TextField(blank=True, default='')

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'notifications'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['recipient', '-created_at']),
            models.Index(fields=['recipient', 'is_read']),
            models.Index(fields=['notification_type']),
            models.Index(fields=['source_type', 'source_id']),
        ]

    def __str__(self):
        return f'[{self.notification_type}] → {self.recipient.username}: {self.title[:50]}'

    def mark_as_read(self):
        if not self.is_read:
            self.is_read = True
            self.read_at = timezone.now()
            self.save(update_fields=['is_read', 'read_at'])
