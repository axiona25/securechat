import uuid
from django.db import models
from django.conf import settings
from django.utils import timezone


class Call(models.Model):
    CALL_TYPES = [('audio', 'Audio'), ('video', 'Video')]
    CALL_STATUS = [
        ('ringing', 'Ringing'),
        ('ongoing', 'Ongoing'),
        ('ended', 'Ended'),
        ('missed', 'Missed'),
        ('rejected', 'Rejected'),
        ('busy', 'Busy'),
        ('failed', 'Failed'),
    ]
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    conversation = models.ForeignKey(
        'chat.Conversation', on_delete=models.CASCADE, related_name='calls'
    )
    call_type = models.CharField(max_length=10, choices=CALL_TYPES)
    status = models.CharField(max_length=10, choices=CALL_STATUS, default='ringing')
    initiated_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='initiated_calls'
    )
    is_group_call = models.BooleanField(default=False)
    # Timestamps
    created_at = models.DateTimeField(auto_now_add=True)
    started_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    duration = models.IntegerField(default=0, help_text='Duration in seconds')

    class Meta:
        db_table = 'calls'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['initiated_by', '-created_at']),
            models.Index(fields=['status']),
        ]

    def __str__(self):
        return f'{self.call_type} call by {self.initiated_by_id} ({self.status})'

    def end_call(self):
        self.status = 'ended'
        self.ended_at = timezone.now()
        if self.started_at:
            self.duration = int((self.ended_at - self.started_at).total_seconds())
        self.save(update_fields=['status', 'ended_at', 'duration'])


class CallParticipant(models.Model):
    call = models.ForeignKey(Call, on_delete=models.CASCADE, related_name='participants')
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name='call_participations'
    )
    joined_at = models.DateTimeField(null=True, blank=True)
    left_at = models.DateTimeField(null=True, blank=True)
    is_muted = models.BooleanField(default=False)
    is_video_off = models.BooleanField(default=False)
    is_speaker_on = models.BooleanField(default=False)

    class Meta:
        db_table = 'call_participants'
        unique_together = ['call', 'user']

    def __str__(self):
        return f'{self.user_id} in call {self.call_id}'


class ICEServer(models.Model):
    """Configurable STUN/TURN servers"""
    SERVER_TYPES = [('stun', 'STUN'), ('turn', 'TURN')]
    server_type = models.CharField(max_length=4, choices=SERVER_TYPES)
    url = models.CharField(max_length=300)
    username = models.CharField(max_length=200, blank=True, default='')
    credential = models.CharField(max_length=200, blank=True, default='')
    is_active = models.BooleanField(default=True)
    priority = models.IntegerField(default=0, help_text='Higher = preferred')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'ice_servers'
        ordering = ['-priority']

    def __str__(self):
        return f'{self.server_type}: {self.url}'

    def to_webrtc_config(self):
        config = {'urls': self.url}
        if self.username:
            config['username'] = self.username
        if self.credential:
            config['credential'] = self.credential
        return config
