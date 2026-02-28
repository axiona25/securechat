import uuid
from django.db import models
from django.conf import settings
from django.utils import timezone


class Conversation(models.Model):
    CONV_TYPES = [
        ('private', 'Private'),
        ('group', 'Group'),
        ('secret', 'Secret'),
    ]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    conv_type = models.CharField(max_length=10, choices=CONV_TYPES, default='private')
    participants = models.ManyToManyField(
        settings.AUTH_USER_MODEL,
        through='ConversationParticipant',
        related_name='conversations'
    )
    last_message = models.ForeignKey(
        'Message', null=True, blank=True,
        on_delete=models.SET_NULL, related_name='+'
    )
    # Secret chat lock
    is_locked = models.BooleanField(default=False)
    lock_hash = models.CharField(max_length=256, blank=True, default='')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'conversations'
        ordering = ['-updated_at']

    def __str__(self):
        return f'{self.conv_type} conversation {self.id}'

    def get_other_participant(self, user):
        """For private chats, get the other user"""
        return self.conversation_participants.exclude(user=user).first()


class ConversationParticipant(models.Model):
    ROLES = [
        ('admin', 'Admin'),
        ('member', 'Member'),
    ]
    conversation = models.ForeignKey(
        Conversation, on_delete=models.CASCADE, related_name='conversation_participants'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='conversation_participations'
    )
    role = models.CharField(max_length=10, choices=ROLES, default='member')
    joined_at = models.DateTimeField(auto_now_add=True)
    muted_until = models.DateTimeField(null=True, blank=True)
    is_pinned = models.BooleanField(default=False)
    is_favorite = models.BooleanField(default=False)
    unread_count = models.IntegerField(default=0)
    last_read_at = models.DateTimeField(null=True, blank=True)
    cleared_at = models.DateTimeField(null=True, blank=True)
    is_hidden = models.BooleanField(default=False)
    is_locked = models.BooleanField(default=False)
    is_blocked = models.BooleanField(default=False)

    class Meta:
        db_table = 'conversation_participants'
        unique_together = ['conversation', 'user']

    def __str__(self):
        return f'{self.user.email} in {self.conversation_id} ({self.role})'


class Message(models.Model):
    MSG_TYPES = [
        ('text', 'Text'),
        ('image', 'Image'),
        ('video', 'Video'),
        ('audio', 'Audio'),
        ('voice', 'Voice Note'),
        ('video_note', 'Video Note'),
        ('file', 'File'),
        ('location', 'Location'),
        ('location_live', 'Live Location'),
        ('contact', 'Contact'),
        ('event', 'Calendar Event'),
        ('system', 'System Message'),
    ]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    conversation = models.ForeignKey(
        Conversation, on_delete=models.CASCADE, related_name='messages'
    )
    sender = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='sent_messages'
    )
    message_type = models.CharField(max_length=15, choices=MSG_TYPES, default='text')
    # Encrypted content (E2E encrypted on client, stored as binary)
    content_encrypted = models.BinaryField(null=True, blank=True)
    # Plaintext content for server-side features (translation, search)
    # This field is optional and only used if user opts in to server-side features
    content_for_translation = models.TextField(blank=True, default='')
    # Reply
    reply_to = models.ForeignKey(
        'self', null=True, blank=True, on_delete=models.SET_NULL, related_name='replies'
    )
    # Forwarding
    is_forwarded = models.BooleanField(default=False)
    forwarded_from = models.ForeignKey(
        'self', null=True, blank=True, on_delete=models.SET_NULL, related_name='forwards'
    )
    # State
    is_deleted = models.BooleanField(default=False)
    deleted_at = models.DateTimeField(null=True, blank=True)
    is_edited = models.BooleanField(default=False)
    edited_at = models.DateTimeField(null=True, blank=True)
    # Timestamps
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'messages'
        ordering = ['created_at']
        indexes = [
            models.Index(fields=['conversation', 'created_at']),
            models.Index(fields=['sender', 'created_at']),
        ]

    def __str__(self):
        return f'{self.message_type} from {self.sender_id} in {self.conversation_id}'

    def can_edit(self):
        """Messages can only be edited within 15 minutes"""
        if self.is_deleted:
            return False
        return (timezone.now() - self.created_at).total_seconds() < 900  # 15 min


class MessageRecipient(models.Model):
    """Per-recipient encrypted payload for group E2E messages (fan-out)."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    message = models.ForeignKey(Message, on_delete=models.CASCADE, related_name='recipients')
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='encrypted_messages')
    content_encrypted = models.BinaryField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('message', 'user')
        indexes = [
            models.Index(fields=['message', 'user']),
        ]

    def __str__(self):
        return f'MessageRecipient {self.message_id} → {self.user_id}'


class Attachment(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    message = models.ForeignKey(
        Message, on_delete=models.CASCADE, related_name='attachments',
        null=True, blank=True,
        help_text='Null until message is sent (upload-first flow for E2EE media)'
    )
    file = models.FileField(upload_to='attachments/%Y/%m/')
    file_name = models.CharField(max_length=255)
    file_size = models.BigIntegerField(default=0)
    mime_type = models.CharField(max_length=100, default='application/octet-stream')
    thumbnail = models.ImageField(upload_to='thumbnails/%Y/%m/', null=True, blank=True)
    # Media metadata
    duration = models.FloatField(null=True, blank=True, help_text='Duration in seconds for audio/video')
    width = models.IntegerField(null=True, blank=True)
    height = models.IntegerField(null=True, blank=True)
    # Encryption (legacy)
    encryption_key_encrypted = models.BinaryField(
        null=True, blank=True,
        help_text='File encryption key, encrypted with message key'
    )
    # E2EE media: server stores only encrypted blobs (zero-knowledge)
    encrypted_file_key = models.TextField(
        blank=True, default='',
        help_text='Base64-encoded file key encrypted with E2EE session key'
    )
    encrypted_metadata = models.TextField(
        blank=True, default='',
        help_text='Base64-encoded encrypted file metadata (filename, mime_type, size, etc.)'
    )
    file_hash = models.CharField(
        max_length=64, blank=True, default='',
        help_text='SHA-256 hash of the original plaintext file for integrity verification'
    )
    is_encrypted = models.BooleanField(
        default=False,
        help_text='Whether this attachment is E2EE encrypted'
    )
    uploaded_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True, blank=True,
        on_delete=models.SET_NULL,
        related_name='uploaded_attachments',
        help_text='User who uploaded this attachment'
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'attachments'

    def __str__(self):
        return f'{self.file_name} ({self.mime_type})'


class MessageStatus(models.Model):
    STATUS_CHOICES = [
        ('sent', 'Sent'),
        ('delivered', 'Delivered'),
        ('read', 'Read'),
    ]
    message = models.ForeignKey(Message, on_delete=models.CASCADE, related_name='statuses')
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='message_statuses'
    )
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='sent')
    timestamp = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'message_statuses'
        unique_together = ['message', 'user']

    def __str__(self):
        return f'{self.message_id} -> {self.user_id}: {self.status}'


class MessageReaction(models.Model):
    message = models.ForeignKey(Message, on_delete=models.CASCADE, related_name='reactions')
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='message_reactions'
    )
    emoji = models.CharField(max_length=10)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'message_reactions'
        unique_together = ['message', 'user']

    def __str__(self):
        return f'{self.user_id} reacted {self.emoji} to {self.message_id}'


class LocationShare(models.Model):
    message = models.OneToOneField(Message, on_delete=models.CASCADE, related_name='location')
    latitude = models.DecimalField(max_digits=10, decimal_places=7)
    longitude = models.DecimalField(max_digits=10, decimal_places=7)
    address = models.CharField(max_length=500, blank=True, default='')
    # Live location
    is_live = models.BooleanField(default=False)
    live_until = models.DateTimeField(null=True, blank=True)
    last_updated = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'location_shares'

    def is_live_active(self):
        if not self.is_live or not self.live_until:
            return False
        return timezone.now() < self.live_until


class ContactShare(models.Model):
    message = models.OneToOneField(Message, on_delete=models.CASCADE, related_name='shared_contact')
    contact_name = models.CharField(max_length=200)
    contact_phone = models.CharField(max_length=50, blank=True, default='')
    contact_email = models.CharField(max_length=200, blank=True, default='')
    vcard_data = models.TextField(blank=True, default='')

    class Meta:
        db_table = 'contact_shares'


class CalendarEvent(models.Model):
    message = models.OneToOneField(Message, on_delete=models.CASCADE, related_name='calendar_event')
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True, default='')
    start_datetime = models.DateTimeField()
    end_datetime = models.DateTimeField()
    location = models.CharField(max_length=300, blank=True, default='')
    attendees = models.ManyToManyField(
        settings.AUTH_USER_MODEL, blank=True, related_name='calendar_events'
    )
    ics_file = models.FileField(upload_to='calendar/', null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'calendar_events'

    def __str__(self):
        return f'{self.title} ({self.start_datetime})'


class Group(models.Model):
    conversation = models.OneToOneField(
        Conversation, on_delete=models.CASCADE, related_name='group_info'
    )
    name = models.CharField(max_length=100)
    description = models.TextField(blank=True, default='')
    avatar = models.ImageField(upload_to='group_avatars/', null=True, blank=True)
    created_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='created_groups'
    )
    max_members = models.IntegerField(default=256)
    # Permissions
    only_admins_can_send = models.BooleanField(default=False)
    only_admins_can_edit = models.BooleanField(default=True)
    only_admins_can_invite = models.BooleanField(default=False)
    # Invite link
    invite_link = models.CharField(max_length=100, unique=True, null=True, blank=True)
    invite_link_expires = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'groups'

    def __str__(self):
        return self.name

    def is_invite_valid(self):
        if not self.invite_link:
            return False
        if self.invite_link_expires and timezone.now() > self.invite_link_expires:
            return False
        return True


class Story(models.Model):
    STORY_TYPES = [('image', 'Image'), ('video', 'Video'), ('text', 'Text')]
    PRIVACY_CHOICES = [
        ('all', 'All Contacts'),
        ('custom', 'Custom List'),
        ('except', 'All Except'),
    ]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='stories'
    )
    story_type = models.CharField(max_length=10, choices=STORY_TYPES)
    media = models.FileField(upload_to='stories/%Y/%m/', null=True, blank=True)
    text_content = models.TextField(blank=True, default='')
    background_color = models.CharField(max_length=7, default='#000000')
    font_style = models.CharField(max_length=30, default='default')
    caption = models.TextField(blank=True, default='')
    privacy = models.CharField(max_length=10, choices=PRIVACY_CHOICES, default='all')
    allowed_users = models.ManyToManyField(
        settings.AUTH_USER_MODEL, blank=True, related_name='visible_stories'
    )
    excluded_users = models.ManyToManyField(
        settings.AUTH_USER_MODEL, blank=True, related_name='hidden_stories'
    )
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    is_active = models.BooleanField(default=True)

    class Meta:
        db_table = 'stories'
        ordering = ['-created_at']

    def __str__(self):
        return f'{self.story_type} story by {self.user_id}'

    def save(self, *args, **kwargs):
        if not self.expires_at:
            self.expires_at = timezone.now() + timezone.timedelta(hours=24)
        super().save(*args, **kwargs)


class StoryView(models.Model):
    story = models.ForeignKey(Story, on_delete=models.CASCADE, related_name='views')
    viewer = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='story_views'
    )
    viewed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'story_views'
        unique_together = ['story', 'viewer']
