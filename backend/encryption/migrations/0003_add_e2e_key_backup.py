# Generated manually for E2E key backup (encrypted blob only)

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('encryption', '0002_add_crypto_version_key_version'),
    ]

    operations = [
        migrations.CreateModel(
            name='E2EKeyBackup',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('version', models.PositiveSmallIntegerField(default=1, help_text='Backup format version for future compatibility')),
                ('kdf_algorithm', models.CharField(help_text='e.g. scrypt, argon2id (client-side only; server does not use)', max_length=32)),
                ('kdf_params', models.JSONField(blank=True, default=dict, help_text='KDF parameters (iterations, etc.) — metadata only')),
                ('salt', models.BinaryField(help_text='Salt used for key derivation (client-side)')),
                ('nonce', models.BinaryField(help_text='Nonce/IV for encryption (client-side)')),
                ('ciphertext', models.BinaryField(help_text='Encrypted key material; server never decrypts')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='e2e_key_backup', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'e2e_key_backups',
                'verbose_name': 'E2E key backup',
                'verbose_name_plural': 'E2E key backups',
            },
        ),
    ]
