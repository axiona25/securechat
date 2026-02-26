from django.db.models import Count
from rest_framework import serializers
from django.utils import timezone
from .models import (
    ChannelCategory, Channel, ChannelMember, ChannelPost,
    PostReaction, PostComment, PostView, Poll, PollOption, PollVote,
)


class ChannelCategorySerializer(serializers.ModelSerializer):
    class Meta:
        model = ChannelCategory
        fields = ['id', 'name', 'slug', 'icon', 'order']
        read_only_fields = ['id']


class ChannelListSerializer(serializers.ModelSerializer):
    owner_username = serializers.CharField(source='owner.username', read_only=True)
    category_name = serializers.CharField(source='category.name', read_only=True, default=None)
    is_member = serializers.SerializerMethodField()

    class Meta:
        model = Channel
        fields = [
            'id', 'name', 'username', 'description', 'avatar',
            'channel_type', 'category', 'category_name',
            'owner_username', 'subscriber_count', 'is_verified',
            'is_member', 'created_at',
        ]
        read_only_fields = ['id', 'subscriber_count', 'is_verified', 'created_at']

    def get_is_member(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            return ChannelMember.objects.filter(
                channel=obj, user=request.user, is_banned=False
            ).exists()
        return False


class ChannelCreateSerializer(serializers.ModelSerializer):
    class Meta:
        model = Channel
        fields = [
            'name', 'username', 'description', 'avatar',
            'channel_type', 'category', 'comments_enabled',
        ]

    def validate_username(self, value):
        value = value.lower().strip()
        if len(value) < 3:
            raise serializers.ValidationError('Username must be at least 3 characters.')
        if not value.replace('_', '').isalnum():
            raise serializers.ValidationError('Username can only contain letters, numbers, and underscores.')
        if Channel.objects.filter(username=value).exists():
            raise serializers.ValidationError('This username is already taken.')
        return value

    def create(self, validated_data):
        user = self.context['request'].user
        channel = Channel.objects.create(owner=user, **validated_data)
        ChannelMember.objects.create(
            channel=channel,
            user=user,
            role=ChannelMember.Role.OWNER,
        )
        channel.subscriber_count = 1
        channel.save(update_fields=['subscriber_count'])
        return channel


class ChannelDetailSerializer(serializers.ModelSerializer):
    owner_username = serializers.CharField(source='owner.username', read_only=True)
    owner_id = serializers.IntegerField(source='owner.id', read_only=True)
    category_name = serializers.CharField(source='category.name', read_only=True, default=None)
    is_member = serializers.SerializerMethodField()
    my_role = serializers.SerializerMethodField()
    invite_link = serializers.SerializerMethodField()

    class Meta:
        model = Channel
        fields = [
            'id', 'name', 'username', 'description', 'avatar',
            'channel_type', 'category', 'category_name',
            'comments_enabled', 'owner_id', 'owner_username',
            'subscriber_count', 'is_verified', 'is_active',
            'invite_code', 'invite_link',
            'is_member', 'my_role',
            'created_at', 'updated_at',
        ]
        read_only_fields = [
            'id', 'owner_id', 'owner_username', 'subscriber_count',
            'is_verified', 'invite_code', 'created_at', 'updated_at',
        ]

    def get_is_member(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            return ChannelMember.objects.filter(
                channel=obj, user=request.user, is_banned=False
            ).exists()
        return False

    def get_my_role(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            membership = ChannelMember.objects.filter(
                channel=obj, user=request.user, is_banned=False
            ).first()
            if membership:
                return membership.role
        return None

    def get_invite_link(self, obj):
        return f'/c/{obj.invite_code}'


class ChannelUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model = Channel
        fields = [
            'name', 'description', 'avatar',
            'channel_type', 'category', 'comments_enabled',
        ]


class ChannelMemberSerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source='user.id', read_only=True)
    username = serializers.CharField(source='user.username', read_only=True)
    display_name = serializers.SerializerMethodField()
    avatar = serializers.SerializerMethodField()

    class Meta:
        model = ChannelMember
        fields = [
            'id', 'user_id', 'username', 'display_name', 'avatar',
            'role', 'is_muted', 'is_banned', 'joined_at',
        ]
        read_only_fields = ['id', 'user_id', 'username', 'joined_at']

    def get_display_name(self, obj):
        u = obj.user
        full = f'{u.first_name} {u.last_name}'.strip()
        return full if full else u.username

    def get_avatar(self, obj):
        if hasattr(obj.user, 'avatar') and obj.user.avatar:
            request = self.context.get('request')
            if request:
                return request.build_absolute_uri(obj.user.avatar.url)
            return obj.user.avatar.url
        return None


class PollOptionSerializer(serializers.ModelSerializer):
    voters = serializers.SerializerMethodField()
    percentage = serializers.SerializerMethodField()

    class Meta:
        model = PollOption
        fields = ['id', 'text', 'vote_count', 'order', 'voters', 'percentage']
        read_only_fields = ['id', 'vote_count']

    def get_voters(self, obj):
        poll = obj.poll
        if poll.is_anonymous:
            return []
        return list(
            PollVote.objects.filter(option=obj)
            .values_list('user__username', flat=True)[:50]
        )

    def get_percentage(self, obj):
        total = obj.poll.total_votes
        if total == 0:
            return 0.0
        return round((obj.vote_count / total) * 100, 1)


class PollSerializer(serializers.ModelSerializer):
    options = PollOptionSerializer(many=True, read_only=True)
    is_expired = serializers.BooleanField(read_only=True)
    my_votes = serializers.SerializerMethodField()

    class Meta:
        model = Poll
        fields = [
            'id', 'question', 'is_anonymous', 'allows_multiple_answers',
            'expires_at', 'total_votes', 'is_expired', 'options', 'my_votes',
            'created_at',
        ]
        read_only_fields = ['id', 'total_votes', 'created_at']

    def get_my_votes(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            return list(
                PollVote.objects.filter(poll=obj, user=request.user)
                .values_list('option_id', flat=True)
            )
        return []


class PostCommentSerializer(serializers.ModelSerializer):
    author_username = serializers.CharField(source='author.username', read_only=True)
    replies_count = serializers.SerializerMethodField()

    class Meta:
        model = PostComment
        fields = [
            'id', 'post', 'author', 'author_username', 'text',
            'parent', 'replies_count', 'created_at', 'updated_at',
        ]
        read_only_fields = ['id', 'author', 'created_at', 'updated_at']

    def get_replies_count(self, obj):
        return obj.replies.count()


class PostReactionSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source='user.username', read_only=True)

    class Meta:
        model = PostReaction
        fields = ['id', 'post', 'user', 'username', 'emoji', 'created_at']
        read_only_fields = ['id', 'user', 'created_at']


class ChannelPostListSerializer(serializers.ModelSerializer):
    author_username = serializers.CharField(source='author.username', read_only=True, default=None)
    poll = PollSerializer(read_only=True)
    reactions_summary = serializers.SerializerMethodField()
    has_viewed = serializers.SerializerMethodField()

    class Meta:
        model = ChannelPost
        fields = [
            'id', 'channel', 'author', 'author_username', 'post_type',
            'text', 'media_file', 'media_filename', 'media_mime_type', 'media_size',
            'is_pinned', 'view_count', 'reaction_count', 'comment_count',
            'poll', 'reactions_summary', 'has_viewed',
            'created_at', 'updated_at',
        ]
        read_only_fields = [
            'id', 'author', 'view_count', 'reaction_count',
            'comment_count', 'created_at', 'updated_at',
        ]

    def get_reactions_summary(self, obj):
        reactions = PostReaction.objects.filter(post=obj).values('emoji').annotate(
            count=Count('id')
        ).order_by('-count')[:10]
        return {r['emoji']: r['count'] for r in reactions}

    def get_has_viewed(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            return PostView.objects.filter(post=obj, user=request.user).exists()
        return False


class ChannelPostCreateSerializer(serializers.Serializer):
    post_type = serializers.ChoiceField(choices=ChannelPost.PostType.choices, default='text')
    text = serializers.CharField(required=False, allow_blank=True, default='')
    media_file = serializers.FileField(required=False, allow_null=True)
    is_scheduled = serializers.BooleanField(required=False, default=False)
    scheduled_at = serializers.DateTimeField(required=False, allow_null=True)

    # Poll fields
    poll_question = serializers.CharField(required=False, max_length=500)
    poll_options = serializers.ListField(
        child=serializers.CharField(max_length=200),
        required=False,
        min_length=2,
        max_length=10,
    )
    poll_is_anonymous = serializers.BooleanField(required=False, default=True)
    poll_allows_multiple = serializers.BooleanField(required=False, default=False)
    poll_expires_at = serializers.DateTimeField(required=False, allow_null=True)

    def validate(self, attrs):
        post_type = attrs.get('post_type', 'text')
        text = attrs.get('text', '')
        media = attrs.get('media_file')

        if post_type == 'text' and not text.strip():
            raise serializers.ValidationError('Text posts must have content.')

        if post_type in ('image', 'video', 'file', 'voice') and not media:
            raise serializers.ValidationError(f'{post_type.title()} posts require a media file.')

        if post_type == 'poll':
            if not attrs.get('poll_question'):
                raise serializers.ValidationError('Poll posts require a question.')
            if not attrs.get('poll_options') or len(attrs.get('poll_options', [])) < 2:
                raise serializers.ValidationError('Poll posts require at least 2 options.')

        if attrs.get('is_scheduled'):
            scheduled_at = attrs.get('scheduled_at')
            if not scheduled_at:
                raise serializers.ValidationError('Scheduled posts require a scheduled_at datetime.')
            if scheduled_at <= timezone.now():
                raise serializers.ValidationError('scheduled_at must be in the future.')

        return attrs


class ChannelStatsSerializer(serializers.Serializer):
    channel_id = serializers.UUIDField()
    channel_name = serializers.CharField()
    subscriber_count = serializers.IntegerField()
    total_posts = serializers.IntegerField()
    total_views = serializers.IntegerField()
    total_reactions = serializers.IntegerField()
    growth_last_7_days = serializers.IntegerField()
    growth_last_30_days = serializers.IntegerField()
    top_posts = ChannelPostListSerializer(many=True)
