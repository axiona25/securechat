import uuid
import string
import secrets
from django.db import models
from django.conf import settings
from django.utils import timezone


def generate_invite_code():
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(12))


def channel_avatar_path(instance, filename):
    ext = filename.rsplit('.', 1)[-1].lower()
    return f'channels/avatars/{instance.id}/{uuid.uuid4().hex}.{ext}'


def post_media_path(instance, filename):
    ext = filename.rsplit('.', 1)[-1].lower()
    return f'channels/posts/{instance.channel_id}/{uuid.uuid4().hex}.{ext}'


class ChannelCategory(models.Model):
    name = models.CharField(max_length=100, unique=True)
    slug = models.SlugField(max_length=100, unique=True)
    icon = models.CharField(max_length=50, blank=True, default='')
    order = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'channel_categories'
        ordering = ['order', 'name']
        verbose_name_plural = 'Channel Categories'

    def __str__(self):
        return self.name


class Channel(models.Model):
    class ChannelType(models.TextChoices):
        PUBLIC = 'public', 'Public'
        PRIVATE = 'private', 'Private'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='owned_channels'
    )
    name = models.CharField(max_length=255)
    username = models.CharField(max_length=64, unique=True, db_index=True)
    description = models.TextField(blank=True, default='')
    avatar = models.ImageField(upload_to=channel_avatar_path, blank=True, null=True)
    category = models.ForeignKey(
        ChannelCategory,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='channels'
    )
    channel_type = models.CharField(
        max_length=10,
        choices=ChannelType.choices,
        default=ChannelType.PUBLIC
    )
    invite_code = models.CharField(max_length=20, unique=True, default=generate_invite_code)
    comments_enabled = models.BooleanField(default=False)
    subscriber_count = models.PositiveIntegerField(default=0)
    is_verified = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'channels'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['username']),
            models.Index(fields=['channel_type', 'is_active']),
            models.Index(fields=['-subscriber_count']),
        ]

    def __str__(self):
        return f'@{self.username} — {self.name}'

    def regenerate_invite_code(self):
        self.invite_code = generate_invite_code()
        self.save(update_fields=['invite_code'])
        return self.invite_code


class ChannelMember(models.Model):
    class Role(models.TextChoices):
        OWNER = 'owner', 'Owner'
        ADMIN = 'admin', 'Admin'
        SUBSCRIBER = 'subscriber', 'Subscriber'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    channel = models.ForeignKey(
        Channel,
        on_delete=models.CASCADE,
        related_name='members'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='channel_memberships'
    )
    role = models.CharField(
        max_length=12,
        choices=Role.choices,
        default=Role.SUBSCRIBER
    )
    is_muted = models.BooleanField(default=False)
    is_banned = models.BooleanField(default=False)
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'channel_members'
        unique_together = ('channel', 'user')
        indexes = [
            models.Index(fields=['channel', 'role']),
            models.Index(fields=['user', 'is_banned']),
        ]

    def __str__(self):
        return f'{self.user} in @{self.channel.username} ({self.role})'


class ChannelPost(models.Model):
    class PostType(models.TextChoices):
        TEXT = 'text', 'Text'
        IMAGE = 'image', 'Image'
        VIDEO = 'video', 'Video'
        FILE = 'file', 'File'
        VOICE = 'voice', 'Voice'
        POLL = 'poll', 'Poll'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    channel = models.ForeignKey(
        Channel,
        on_delete=models.CASCADE,
        related_name='posts'
    )
    author = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        related_name='channel_posts'
    )
    post_type = models.CharField(
        max_length=10,
        choices=PostType.choices,
        default=PostType.TEXT
    )
    text = models.TextField(blank=True, default='')
    media_file = models.FileField(upload_to=post_media_path, blank=True, null=True)
    media_filename = models.CharField(max_length=255, blank=True, default='')
    media_mime_type = models.CharField(max_length=100, blank=True, default='')
    media_size = models.PositiveBigIntegerField(default=0)

    is_pinned = models.BooleanField(default=False)
    is_scheduled = models.BooleanField(default=False)
    scheduled_at = models.DateTimeField(null=True, blank=True)
    is_published = models.BooleanField(default=True)

    view_count = models.PositiveIntegerField(default=0)
    reaction_count = models.PositiveIntegerField(default=0)
    comment_count = models.PositiveIntegerField(default=0)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'channel_posts'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['channel', '-created_at']),
            models.Index(fields=['channel', 'is_pinned']),
            models.Index(fields=['is_scheduled', 'scheduled_at']),
            models.Index(fields=['is_published']),
        ]

    def __str__(self):
        return f'Post {self.id} in @{self.channel.username}'


class PostReaction(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    post = models.ForeignKey(
        ChannelPost,
        on_delete=models.CASCADE,
        related_name='reactions'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='channel_post_reactions'
    )
    emoji = models.CharField(max_length=10)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'channel_post_reactions'
        unique_together = ('post', 'user', 'emoji')

    def __str__(self):
        return f'{self.user} reacted {self.emoji} on {self.post_id}'


class PostComment(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    post = models.ForeignKey(
        ChannelPost,
        on_delete=models.CASCADE,
        related_name='comments'
    )
    author = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='channel_post_comments'
    )
    text = models.TextField(max_length=2000)
    parent = models.ForeignKey(
        'self',
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name='replies'
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'channel_post_comments'
        ordering = ['created_at']
        indexes = [
            models.Index(fields=['post', 'created_at']),
        ]

    def __str__(self):
        return f'Comment by {self.author} on post {self.post_id}'


class PostView(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    post = models.ForeignKey(
        ChannelPost,
        on_delete=models.CASCADE,
        related_name='views'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='channel_post_views'
    )
    viewed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'channel_post_views'
        unique_together = ('post', 'user')

    def __str__(self):
        return f'{self.user} viewed {self.post_id}'


class Poll(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    post = models.OneToOneField(
        ChannelPost,
        on_delete=models.CASCADE,
        related_name='poll'
    )
    question = models.CharField(max_length=500)
    is_anonymous = models.BooleanField(default=True)
    allows_multiple_answers = models.BooleanField(default=False)
    expires_at = models.DateTimeField(null=True, blank=True)
    total_votes = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'channel_polls'

    def __str__(self):
        return f'Poll: {self.question[:60]}'

    @property
    def is_expired(self):
        if self.expires_at is None:
            return False
        return timezone.now() >= self.expires_at


class PollOption(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    poll = models.ForeignKey(
        Poll,
        on_delete=models.CASCADE,
        related_name='options'
    )
    text = models.CharField(max_length=200)
    vote_count = models.PositiveIntegerField(default=0)
    order = models.PositiveSmallIntegerField(default=0)

    class Meta:
        db_table = 'channel_poll_options'
        ordering = ['order']

    def __str__(self):
        return f'{self.text} ({self.vote_count} votes)'


class PollVote(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    poll = models.ForeignKey(
        Poll,
        on_delete=models.CASCADE,
        related_name='votes'
    )
    option = models.ForeignKey(
        PollOption,
        on_delete=models.CASCADE,
        related_name='votes'
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='channel_poll_votes'
    )
    voted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'channel_poll_votes'
        indexes = [
            models.Index(fields=['poll', 'user']),
        ]

    def __str__(self):
        return f'{self.user} voted on {self.poll_id}'
