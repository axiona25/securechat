from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion
import django.utils.timezone


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='SecurityAlert',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('alert_type', models.CharField(choices=[('excessive_fetch', 'Excessive Key Bundle Fetches'), ('prekey_exhaustion', 'PreKey Pool Exhausted'), ('identity_change', 'Identity Key Changed'), ('multi_device_anomaly', 'Multiple Device Anomaly'), ('brute_force', 'Brute Force Attempt')], max_length=30)),
                ('severity', models.CharField(choices=[('low', 'Low'), ('medium', 'Medium'), ('high', 'High'), ('critical', 'Critical')], default='medium', max_length=10)),
                ('message', models.TextField()),
                ('metadata', models.JSONField(blank=True, default=dict)),
                ('is_resolved', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('resolved_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='security_alerts', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'security_alerts',
                'ordering': ['-created_at'],
            },
        ),
        migrations.CreateModel(
            name='UserKeyBundle',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('identity_key_public', models.BinaryField(help_text='Ed448 public key for identity verification (57 bytes)')),
                ('identity_dh_public', models.BinaryField(help_text='X448 public key derived for DH identity operations (56 bytes)', null=True)),
                ('signed_prekey_public', models.BinaryField(help_text='X448 signed prekey public (56 bytes)')),
                ('signed_prekey_signature', models.BinaryField(help_text='Ed448 signature over signed prekey')),
                ('signed_prekey_id', models.IntegerField(default=0)),
                ('signed_prekey_created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('uploaded_at', models.DateTimeField(auto_now=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='key_bundle', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'user_key_bundles',
            },
        ),
        migrations.CreateModel(
            name='SessionKey',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('session_data', models.BinaryField(help_text='Encrypted serialized ratchet state')),
                ('session_version', models.IntegerField(default=1)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('peer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='ratchet_sessions_peer', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='ratchet_sessions_owned', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'session_keys',
                'unique_together': {('user', 'peer')},
            },
        ),
        migrations.CreateModel(
            name='OneTimePreKey',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key_id', models.IntegerField()),
                ('public_key', models.BinaryField(help_text='X448 one-time prekey (56 bytes)')),
                ('is_used', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('used_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='one_time_prekeys', to=settings.AUTH_USER_MODEL)),
                ('used_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='consumed_prekeys', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'one_time_prekeys',
                'ordering': ['key_id'],
                'unique_together': {('user', 'key_id')},
            },
        ),
        migrations.CreateModel(
            name='KeyBundleFetchLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('ip_address', models.GenericIPAddressField(null=True)),
                ('user_agent', models.CharField(blank=True, max_length=500)),
                ('fetched_at', models.DateTimeField(auto_now_add=True)),
                ('requester', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='key_fetch_logs', to=settings.AUTH_USER_MODEL)),
                ('target_user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='key_fetched_logs', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'key_bundle_fetch_logs',
                'ordering': ['-fetched_at'],
            },
        ),
    ]
