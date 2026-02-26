"""
Migration: Add E2EE encryption fields to Attachment model.
Run: python manage.py migrate chat
"""
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('chat', '0001_initial'),
    ]

    operations = [
        migrations.AddField(
            model_name='attachment',
            name='encrypted_file_key',
            field=models.TextField(
                blank=True,
                default='',
                help_text='Base64-encoded file key encrypted with E2EE session key',
            ),
        ),
        migrations.AddField(
            model_name='attachment',
            name='encrypted_metadata',
            field=models.TextField(
                blank=True,
                default='',
                help_text='Base64-encoded encrypted file metadata (filename, mime_type, size, etc.)',
            ),
        ),
        migrations.AddField(
            model_name='attachment',
            name='file_hash',
            field=models.CharField(
                max_length=64,
                blank=True,
                default='',
                help_text='SHA-256 hash of the original plaintext file for integrity verification',
            ),
        ),
        migrations.AddField(
            model_name='attachment',
            name='is_encrypted',
            field=models.BooleanField(
                default=False,
                help_text='Whether this attachment is E2EE encrypted',
            ),
        ),
        migrations.AddField(
            model_name='attachment',
            name='uploaded_by',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='uploaded_attachments',
                to=settings.AUTH_USER_MODEL,
                help_text='User who uploaded this attachment',
            ),
        ),
        migrations.AlterField(
            model_name='attachment',
            name='message',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='attachments',
                to='chat.message',
                help_text='Null until message is sent (upload-first flow for E2EE media)',
            ),
        ),
    ]
