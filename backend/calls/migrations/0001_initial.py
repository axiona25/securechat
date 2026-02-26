import uuid
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        ('chat', '0001_initial'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='ICEServer',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('server_type', models.CharField(choices=[('stun', 'STUN'), ('turn', 'TURN')], max_length=4)),
                ('url', models.CharField(max_length=300)),
                ('username', models.CharField(blank=True, default='', max_length=200)),
                ('credential', models.CharField(blank=True, default='', max_length=200)),
                ('is_active', models.BooleanField(default=True)),
                ('priority', models.IntegerField(default=0, help_text='Higher = preferred')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'db_table': 'ice_servers',
                'ordering': ['-priority'],
            },
        ),
        migrations.CreateModel(
            name='Call',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('call_type', models.CharField(choices=[('audio', 'Audio'), ('video', 'Video')], max_length=10)),
                ('status', models.CharField(choices=[('ringing', 'Ringing'), ('ongoing', 'Ongoing'), ('ended', 'Ended'), ('missed', 'Missed'), ('rejected', 'Rejected'), ('busy', 'Busy'), ('failed', 'Failed')], default='ringing', max_length=10)),
                ('is_group_call', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('started_at', models.DateTimeField(blank=True, null=True)),
                ('ended_at', models.DateTimeField(blank=True, null=True)),
                ('duration', models.IntegerField(default=0, help_text='Duration in seconds')),
                ('conversation', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='calls', to='chat.conversation')),
                ('initiated_by', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='initiated_calls', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'calls',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='call',
            index=models.Index(fields=['initiated_by', '-created_at'], name='calls_initiat_created_idx'),
        ),
        migrations.AddIndex(
            model_name='call',
            index=models.Index(fields=['status'], name='calls_status_idx'),
        ),
        migrations.CreateModel(
            name='CallParticipant',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('joined_at', models.DateTimeField(blank=True, null=True)),
                ('left_at', models.DateTimeField(blank=True, null=True)),
                ('is_muted', models.BooleanField(default=False)),
                ('is_video_off', models.BooleanField(default=False)),
                ('is_speaker_on', models.BooleanField(default=False)),
                ('call', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='participants', to='calls.call')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='call_participations', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'call_participants',
                'unique_together': {('call', 'user')},
            },
        ),
    ]
