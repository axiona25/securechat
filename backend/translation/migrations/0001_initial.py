import uuid
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='TranslationPreference',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('preferred_language', models.CharField(default='en', help_text='ISO 639-1 language code (e.g. en, it, es, de, fr)', max_length=10)),
                ('auto_translate', models.BooleanField(default=False, help_text='Automatically translate incoming messages in all conversations')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='translation_preference', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'translation_preferences',
            },
        ),
        migrations.CreateModel(
            name='ConversationTranslationSetting',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('conversation_id', models.UUIDField(help_text='UUID of the conversation (chat.Conversation)')),
                ('auto_translate', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='conversation_translation_settings', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'translation_conversation_settings',
                'unique_together': {('user', 'conversation_id')},
            },
        ),
        migrations.CreateModel(
            name='TranslationCache',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('cache_key', models.CharField(db_index=True, max_length=64, unique=True)),
                ('source_text', models.TextField()),
                ('translated_text', models.TextField()),
                ('source_language', models.CharField(max_length=10)),
                ('target_language', models.CharField(max_length=10)),
                ('detected_language', models.CharField(blank=True, default='', max_length=10)),
                ('char_count', models.PositiveIntegerField(default=0)),
                ('hit_count', models.PositiveIntegerField(default=0, help_text='Times this cache entry was used')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'db_table': 'translation_cache',
            },
        ),
        migrations.CreateModel(
            name='InstalledLanguagePack',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('source_language', models.CharField(max_length=10)),
                ('source_language_name', models.CharField(blank=True, default='', max_length=100)),
                ('target_language', models.CharField(max_length=10)),
                ('target_language_name', models.CharField(blank=True, default='', max_length=100)),
                ('package_version', models.CharField(blank=True, default='', max_length=50)),
                ('installed_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'db_table': 'translation_language_packs',
                'unique_together': {('source_language', 'target_language')},
            },
        ),
        migrations.CreateModel(
            name='TranslationUsageLog',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('source_language', models.CharField(max_length=10)),
                ('target_language', models.CharField(max_length=10)),
                ('char_count', models.PositiveIntegerField()),
                ('cached', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='translation_usage_logs', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'translation_usage_logs',
            },
        ),
        migrations.AddIndex(
            model_name='translationcache',
            index=models.Index(fields=['source_language', 'target_language'], name='trans_cache_sl_tl_idx'),
        ),
        migrations.AddIndex(
            model_name='translationcache',
            index=models.Index(fields=['created_at'], name='trans_cache_created_idx'),
        ),
        migrations.AddIndex(
            model_name='translationusagelog',
            index=models.Index(fields=['user', 'created_at'], name='trans_usage_user_created_idx'),
        ),
    ]
