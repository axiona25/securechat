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
            name='DeviceToken',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('token', models.CharField(db_index=True, max_length=500)),
                ('platform', models.CharField(choices=[('android', 'Android'), ('ios', 'iOS'), ('web', 'Web')], max_length=10)),
                ('device_id', models.CharField(help_text='Unique device identifier', max_length=255)),
                ('device_name', models.CharField(blank=True, default='', max_length=255)),
                ('is_active', models.BooleanField(default=True)),
                ('last_used_at', models.DateTimeField(auto_now=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='device_tokens', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'notification_device_tokens',
                'unique_together': {('user', 'device_id')},
            },
        ),
        migrations.AddIndex(
            model_name='devicetoken',
            index=models.Index(fields=['user', 'is_active'], name='notification_user_id_idx'),
        ),
        migrations.CreateModel(
            name='NotificationPreference',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('new_message', models.BooleanField(default=True)),
                ('message_reaction', models.BooleanField(default=True)),
                ('mention', models.BooleanField(default=True)),
                ('incoming_call', models.BooleanField(default=True)),
                ('missed_call', models.BooleanField(default=True)),
                ('channel_post', models.BooleanField(default=True)),
                ('group_invite', models.BooleanField(default=True)),
                ('channel_invite', models.BooleanField(default=True)),
                ('security_alert', models.BooleanField(default=True)),
                ('dnd_enabled', models.BooleanField(default=False)),
                ('dnd_start_time', models.TimeField(blank=True, help_text='DND start (local time)', null=True)),
                ('dnd_end_time', models.TimeField(blank=True, help_text='DND end (local time)', null=True)),
                ('sound_enabled', models.BooleanField(default=True)),
                ('vibration_enabled', models.BooleanField(default=True)),
                ('show_preview', models.BooleanField(default=True, help_text='Show message content in notification')),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='notification_preferences', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'notification_preferences',
            },
        ),
        migrations.CreateModel(
            name='MuteRule',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('target_type', models.CharField(choices=[('conversation', 'Conversation'), ('group', 'Group'), ('channel', 'Channel')], max_length=15)),
                ('target_id', models.CharField(help_text='UUID of conversation, group, or channel', max_length=36)),
                ('muted_until', models.DateTimeField(blank=True, help_text='Null = muted forever, datetime = muted until', null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='mute_rules', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'notification_mute_rules',
                'unique_together': {('user', 'target_type', 'target_id')},
            },
        ),
        migrations.AddIndex(
            model_name='muterule',
            index=models.Index(fields=['user', 'target_type', 'target_id'], name='notification_mute_user_idx'),
        ),
        migrations.CreateModel(
            name='Notification',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('notification_type', models.CharField(choices=[('new_message', 'New Message'), ('message_reaction', 'Message Reaction'), ('mention', 'Mention'), ('incoming_call', 'Incoming Call'), ('missed_call', 'Missed Call'), ('channel_post', 'Channel Post'), ('group_invite', 'Group Invite'), ('channel_invite', 'Channel Invite'), ('security_alert', 'Security Alert')], max_length=20)),
                ('title', models.CharField(max_length=255)),
                ('body', models.TextField(max_length=1000)),
                ('data', models.JSONField(blank=True, default=dict, help_text='Extra payload sent to client')),
                ('source_type', models.CharField(blank=True, default='', help_text='e.g. message, call, channel_post', max_length=50)),
                ('source_id', models.CharField(blank=True, default='', help_text='UUID of source object', max_length=36)),
                ('is_read', models.BooleanField(default=False)),
                ('read_at', models.DateTimeField(blank=True, null=True)),
                ('fcm_sent', models.BooleanField(default=False)),
                ('fcm_message_id', models.CharField(blank=True, default='', max_length=255)),
                ('fcm_error', models.TextField(blank=True, default='')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('recipient', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='notifications', to=settings.AUTH_USER_MODEL)),
                ('sender', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='sent_notifications', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'notifications',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='notification',
            index=models.Index(fields=['recipient', '-created_at'], name='notification_recipient_idx'),
        ),
        migrations.AddIndex(
            model_name='notification',
            index=models.Index(fields=['recipient', 'is_read'], name='notification_is_read_idx'),
        ),
        migrations.AddIndex(
            model_name='notification',
            index=models.Index(fields=['notification_type'], name='notification_type_idx'),
        ),
        migrations.AddIndex(
            model_name='notification',
            index=models.Index(fields=['source_type', 'source_id'], name='notification_source_idx'),
        ),
    ]
