import uuid
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion
import channels_pub.models


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='ChannelCategory',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=100, unique=True)),
                ('slug', models.SlugField(max_length=100, unique=True)),
                ('icon', models.CharField(blank=True, default='', max_length=50)),
                ('order', models.PositiveIntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'db_table': 'channel_categories',
                'ordering': ['order', 'name'],
                'verbose_name_plural': 'Channel Categories',
            },
        ),
        migrations.CreateModel(
            name='Channel',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('name', models.CharField(max_length=255)),
                ('username', models.CharField(db_index=True, max_length=64, unique=True)),
                ('description', models.TextField(blank=True, default='')),
                ('avatar', models.ImageField(blank=True, null=True, upload_to=channels_pub.models.channel_avatar_path)),
                ('channel_type', models.CharField(choices=[('public', 'Public'), ('private', 'Private')], default='public', max_length=10)),
                ('invite_code', models.CharField(default=channels_pub.models.generate_invite_code, max_length=20, unique=True)),
                ('comments_enabled', models.BooleanField(default=False)),
                ('subscriber_count', models.PositiveIntegerField(default=0)),
                ('is_verified', models.BooleanField(default=False)),
                ('is_active', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('category', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='channels', to='channels_pub.channelcategory')),
                ('owner', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='owned_channels', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'channels',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='channel',
            index=models.Index(fields=['username'], name='channels_usernam_idx'),
        ),
        migrations.AddIndex(
            model_name='channel',
            index=models.Index(fields=['channel_type', 'is_active'], name='channels_channel_idx'),
        ),
        migrations.AddIndex(
            model_name='channel',
            index=models.Index(fields=['-subscriber_count'], name='channels_subscr_idx'),
        ),
        migrations.CreateModel(
            name='ChannelMember',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('role', models.CharField(choices=[('owner', 'Owner'), ('admin', 'Admin'), ('subscriber', 'Subscriber')], default='subscriber', max_length=12)),
                ('is_muted', models.BooleanField(default=False)),
                ('is_banned', models.BooleanField(default=False)),
                ('joined_at', models.DateTimeField(auto_now_add=True)),
                ('channel', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='members', to='channels_pub.channel')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='channel_memberships', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'channel_members',
                'unique_together': {('channel', 'user')},
            },
        ),
        migrations.AddIndex(
            model_name='channelmember',
            index=models.Index(fields=['channel', 'role'], name='channel_me_channel_idx'),
        ),
        migrations.AddIndex(
            model_name='channelmember',
            index=models.Index(fields=['user', 'is_banned'], name='channel_me_user_id_idx'),
        ),
        migrations.CreateModel(
            name='ChannelPost',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('post_type', models.CharField(choices=[('text', 'Text'), ('image', 'Image'), ('video', 'Video'), ('file', 'File'), ('voice', 'Voice'), ('poll', 'Poll')], default='text', max_length=10)),
                ('text', models.TextField(blank=True, default='')),
                ('media_file', models.FileField(blank=True, null=True, upload_to=channels_pub.models.post_media_path)),
                ('media_filename', models.CharField(blank=True, default='', max_length=255)),
                ('media_mime_type', models.CharField(blank=True, default='', max_length=100)),
                ('media_size', models.PositiveBigIntegerField(default=0)),
                ('is_pinned', models.BooleanField(default=False)),
                ('is_scheduled', models.BooleanField(default=False)),
                ('scheduled_at', models.DateTimeField(blank=True, null=True)),
                ('is_published', models.BooleanField(default=True)),
                ('view_count', models.PositiveIntegerField(default=0)),
                ('reaction_count', models.PositiveIntegerField(default=0)),
                ('comment_count', models.PositiveIntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('author', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='channel_posts', to=settings.AUTH_USER_MODEL)),
                ('channel', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='posts', to='channels_pub.channel')),
            ],
            options={
                'db_table': 'channel_posts',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='channelpost',
            index=models.Index(fields=['channel', '-created_at'], name='channel_po_channel_idx'),
        ),
        migrations.AddIndex(
            model_name='channelpost',
            index=models.Index(fields=['channel', 'is_pinned'], name='channel_po_is_pinn_idx'),
        ),
        migrations.AddIndex(
            model_name='channelpost',
            index=models.Index(fields=['is_scheduled', 'scheduled_at'], name='channel_po_is_sche_idx'),
        ),
        migrations.AddIndex(
            model_name='channelpost',
            index=models.Index(fields=['is_published'], name='channel_po_is_publ_idx'),
        ),
        migrations.CreateModel(
            name='Poll',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('question', models.CharField(max_length=500)),
                ('is_anonymous', models.BooleanField(default=True)),
                ('allows_multiple_answers', models.BooleanField(default=False)),
                ('expires_at', models.DateTimeField(blank=True, null=True)),
                ('total_votes', models.PositiveIntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('post', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='poll', to='channels_pub.channelpost')),
            ],
            options={
                'db_table': 'channel_polls',
            },
        ),
        migrations.CreateModel(
            name='PollOption',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('text', models.CharField(max_length=200)),
                ('vote_count', models.PositiveIntegerField(default=0)),
                ('order', models.PositiveSmallIntegerField(default=0)),
                ('poll', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='options', to='channels_pub.poll')),
            ],
            options={
                'db_table': 'channel_poll_options',
                'ordering': ['order'],
            },
        ),
        migrations.CreateModel(
            name='PostReaction',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('emoji', models.CharField(max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('post', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='reactions', to='channels_pub.channelpost')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='channel_post_reactions', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'channel_post_reactions',
                'unique_together': {('post', 'user', 'emoji')},
            },
        ),
        migrations.CreateModel(
            name='PostComment',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('text', models.TextField(max_length=2000)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('author', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='channel_post_comments', to=settings.AUTH_USER_MODEL)),
                ('parent', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='replies', to='channels_pub.postcomment')),
                ('post', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='comments', to='channels_pub.channelpost')),
            ],
            options={
                'db_table': 'channel_post_comments',
                'ordering': ['created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='postcomment',
            index=models.Index(fields=['post', 'created_at'], name='channel_po_post_id_idx'),
        ),
        migrations.CreateModel(
            name='PostView',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('viewed_at', models.DateTimeField(auto_now_add=True)),
                ('post', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='views', to='channels_pub.channelpost')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='channel_post_views', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'channel_post_views',
                'unique_together': {('post', 'user')},
            },
        ),
        migrations.CreateModel(
            name='PollVote',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('voted_at', models.DateTimeField(auto_now_add=True)),
                ('option', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='votes', to='channels_pub.polloption')),
                ('poll', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='votes', to='channels_pub.poll')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='channel_poll_votes', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'channel_poll_votes',
            },
        ),
        migrations.AddIndex(
            model_name='pollvote',
            index=models.Index(fields=['poll', 'user'], name='channel_po_poll_id_idx'),
        ),
    ]
