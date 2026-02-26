import uuid
from django.db import models
from django.conf import settings


class TranslationPreference(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='translation_preference'
    )
    preferred_language = models.CharField(
        max_length=10,
        default='en',
        help_text='ISO 639-1 language code (e.g. en, it, es, de, fr)'
    )
    auto_translate = models.BooleanField(
        default=False,
        help_text='Automatically translate incoming messages in all conversations'
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'translation_preferences'

    def __str__(self):
        return f'{self.user.username} → {self.preferred_language} (auto={self.auto_translate})'


class ConversationTranslationSetting(models.Model):
    """Per-conversation auto-translate toggle."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='conversation_translation_settings'
    )
    conversation_id = models.UUIDField(
        help_text='UUID of the conversation (chat.Conversation)'
    )
    auto_translate = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'translation_conversation_settings'
        unique_together = ('user', 'conversation_id')

    def __str__(self):
        return f'{self.user.username} conv:{self.conversation_id} auto={self.auto_translate}'


class TranslationCache(models.Model):
    """
    Persistent translation cache.
    Key: hash of (source_text + source_lang + target_lang).
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    cache_key = models.CharField(max_length=64, unique=True, db_index=True)
    source_text = models.TextField()
    translated_text = models.TextField()
    source_language = models.CharField(max_length=10)
    target_language = models.CharField(max_length=10)
    detected_language = models.CharField(max_length=10, blank=True, default='')
    char_count = models.PositiveIntegerField(default=0)
    hit_count = models.PositiveIntegerField(default=0, help_text='Times this cache entry was used')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'translation_cache'
        indexes = [
            models.Index(fields=['source_language', 'target_language']),
            models.Index(fields=['created_at']),
        ]

    def __str__(self):
        return f'{self.source_language}→{self.target_language}: {self.source_text[:40]}'


class InstalledLanguagePack(models.Model):
    """Track which Argos Translate language packs are installed."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    source_language = models.CharField(max_length=10)
    source_language_name = models.CharField(max_length=100, blank=True, default='')
    target_language = models.CharField(max_length=10)
    target_language_name = models.CharField(max_length=100, blank=True, default='')
    package_version = models.CharField(max_length=50, blank=True, default='')
    installed_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'translation_language_packs'
        unique_together = ('source_language', 'target_language')

    def __str__(self):
        return f'{self.source_language_name} ({self.source_language}) → {self.target_language_name} ({self.target_language})'


class TranslationUsageLog(models.Model):
    """Track translation usage per user for monitoring."""
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='translation_usage_logs'
    )
    source_language = models.CharField(max_length=10)
    target_language = models.CharField(max_length=10)
    char_count = models.PositiveIntegerField()
    cached = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'translation_usage_logs'
        indexes = [
            models.Index(fields=['user', 'created_at']),
        ]

    def __str__(self):
        return f'{self.user.username} {self.source_language}→{self.target_language} {self.char_count}ch'
