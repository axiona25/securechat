import uuid
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
            name='Conversation',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('conv_type', models.CharField(choices=[('private', 'Private'), ('group', 'Group'), ('secret', 'Secret')], default='private', max_length=10)),
                ('is_locked', models.BooleanField(default=False)),
                ('lock_hash', models.CharField(blank=True, default='', max_length=256)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'db_table': 'conversations',
                'ordering': ['-updated_at'],
            },
        ),
        migrations.CreateModel(
            name='ConversationParticipant',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('role', models.CharField(choices=[('admin', 'Admin'), ('member', 'Member')], default='member', max_length=10)),
                ('joined_at', models.DateTimeField(auto_now_add=True)),
                ('muted_until', models.DateTimeField(blank=True, null=True)),
                ('is_pinned', models.BooleanField(default=False)),
                ('unread_count', models.IntegerField(default=0)),
                ('last_read_at', models.DateTimeField(blank=True, null=True)),
                ('conversation', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='conversation_participants', to='chat.conversation')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='conversation_participations', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'conversation_participants',
                'unique_together': {('conversation', 'user')},
            },
        ),
        migrations.CreateModel(
            name='Message',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('message_type', models.CharField(choices=[('text', 'Text'), ('image', 'Image'), ('video', 'Video'), ('audio', 'Audio'), ('voice', 'Voice Note'), ('video_note', 'Video Note'), ('file', 'File'), ('location', 'Location'), ('location_live', 'Live Location'), ('contact', 'Contact'), ('event', 'Calendar Event'), ('system', 'System Message')], default='text', max_length=15)),
                ('content_encrypted', models.BinaryField(blank=True, null=True)),
                ('content_for_translation', models.TextField(blank=True, default='')),
                ('is_forwarded', models.BooleanField(default=False)),
                ('is_deleted', models.BooleanField(default=False)),
                ('deleted_at', models.DateTimeField(blank=True, null=True)),
                ('is_edited', models.BooleanField(default=False)),
                ('edited_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('conversation', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='messages', to='chat.conversation')),
                ('sender', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='sent_messages', to=settings.AUTH_USER_MODEL)),
                ('reply_to', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='replies', to='chat.message')),
                ('forwarded_from', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='forwards', to='chat.message')),
            ],
            options={
                'db_table': 'messages',
                'ordering': ['created_at'],
            },
        ),
        migrations.AddField(
            model_name='conversation',
            name='last_message',
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='chat.message'),
        ),
        migrations.AddIndex(
            model_name='message',
            index=models.Index(fields=['conversation', 'created_at'], name='messages_convers_created_idx'),
        ),
        migrations.AddIndex(
            model_name='message',
            index=models.Index(fields=['sender', 'created_at'], name='messages_sender__created_idx'),
        ),
        migrations.CreateModel(
            name='Attachment',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('file', models.FileField(upload_to='attachments/%Y/%m/')),
                ('file_name', models.CharField(max_length=255)),
                ('file_size', models.BigIntegerField(default=0)),
                ('mime_type', models.CharField(default='application/octet-stream', max_length=100)),
                ('thumbnail', models.ImageField(blank=True, null=True, upload_to='thumbnails/%Y/%m/')),
                ('duration', models.FloatField(blank=True, help_text='Duration in seconds for audio/video', null=True)),
                ('width', models.IntegerField(blank=True, null=True)),
                ('height', models.IntegerField(blank=True, null=True)),
                ('encryption_key_encrypted', models.BinaryField(blank=True, help_text='File encryption key, encrypted with message key', null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('message', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='attachments', to='chat.message')),
            ],
            options={
                'db_table': 'attachments',
            },
        ),
        migrations.CreateModel(
            name='MessageStatus',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('status', models.CharField(choices=[('sent', 'Sent'), ('delivered', 'Delivered'), ('read', 'Read')], default='sent', max_length=10)),
                ('timestamp', models.DateTimeField(auto_now=True)),
                ('message', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='statuses', to='chat.message')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='message_statuses', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'message_statuses',
                'unique_together': {('message', 'user')},
            },
        ),
        migrations.CreateModel(
            name='MessageReaction',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('emoji', models.CharField(max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('message', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='reactions', to='chat.message')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='message_reactions', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'message_reactions',
                'unique_together': {('message', 'user')},
            },
        ),
        migrations.CreateModel(
            name='LocationShare',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('latitude', models.DecimalField(decimal_places=7, max_digits=10)),
                ('longitude', models.DecimalField(decimal_places=7, max_digits=10)),
                ('address', models.CharField(blank=True, default='', max_length=500)),
                ('is_live', models.BooleanField(default=False)),
                ('live_until', models.DateTimeField(blank=True, null=True)),
                ('last_updated', models.DateTimeField(auto_now=True)),
                ('message', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='location', to='chat.message')),
            ],
            options={
                'db_table': 'location_shares',
            },
        ),
        migrations.CreateModel(
            name='ContactShare',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('contact_name', models.CharField(max_length=200)),
                ('contact_phone', models.CharField(blank=True, default='', max_length=50)),
                ('contact_email', models.CharField(blank=True, default='', max_length=200)),
                ('vcard_data', models.TextField(blank=True, default='')),
                ('message', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='shared_contact', to='chat.message')),
            ],
            options={
                'db_table': 'contact_shares',
            },
        ),
        migrations.CreateModel(
            name='CalendarEvent',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('title', models.CharField(max_length=200)),
                ('description', models.TextField(blank=True, default='')),
                ('start_datetime', models.DateTimeField()),
                ('end_datetime', models.DateTimeField()),
                ('location', models.CharField(blank=True, default='', max_length=300)),
                ('ics_file', models.FileField(blank=True, null=True, upload_to='calendar/')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('message', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='calendar_event', to='chat.message')),
                ('attendees', models.ManyToManyField(blank=True, related_name='calendar_events', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'calendar_events',
            },
        ),
        migrations.CreateModel(
            name='Group',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=100)),
                ('description', models.TextField(blank=True, default='')),
                ('avatar', models.ImageField(blank=True, null=True, upload_to='group_avatars/')),
                ('max_members', models.IntegerField(default=256)),
                ('only_admins_can_send', models.BooleanField(default=False)),
                ('only_admins_can_edit', models.BooleanField(default=True)),
                ('only_admins_can_invite', models.BooleanField(default=False)),
                ('invite_link', models.CharField(blank=True, max_length=100, null=True, unique=True)),
                ('invite_link_expires', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('conversation', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='group_info', to='chat.conversation')),
                ('created_by', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='created_groups', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'groups',
            },
        ),
        migrations.CreateModel(
            name='Story',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('story_type', models.CharField(choices=[('image', 'Image'), ('video', 'Video'), ('text', 'Text')], max_length=10)),
                ('media', models.FileField(blank=True, null=True, upload_to='stories/%Y/%m/')),
                ('text_content', models.TextField(blank=True, default='')),
                ('background_color', models.CharField(default='#000000', max_length=7)),
                ('font_style', models.CharField(default='default', max_length=30)),
                ('caption', models.TextField(blank=True, default='')),
                ('privacy', models.CharField(choices=[('all', 'All Contacts'), ('custom', 'Custom List'), ('except', 'All Except')], default='all', max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('expires_at', models.DateTimeField()),
                ('is_active', models.BooleanField(default=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='stories', to=settings.AUTH_USER_MODEL)),
                ('allowed_users', models.ManyToManyField(blank=True, related_name='visible_stories', to=settings.AUTH_USER_MODEL)),
                ('excluded_users', models.ManyToManyField(blank=True, related_name='hidden_stories', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'stories',
                'ordering': ['-created_at'],
            },
        ),
        migrations.CreateModel(
            name='StoryView',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('viewed_at', models.DateTimeField(auto_now_add=True)),
                ('story', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='views', to='chat.story')),
                ('viewer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='story_views', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'story_views',
                'unique_together': {('story', 'viewer')},
            },
        ),
    ]
