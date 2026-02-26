from rest_framework import serializers
from django.contrib.auth import get_user_model

User = get_user_model()


# ────────────────────────── Auth ──────────────────────────

class AdminLoginSerializer(serializers.Serializer):
    username = serializers.CharField()
    password = serializers.CharField(write_only=True)


# ────────────────────────── Users ──────────────────────────

class AdminUserListSerializer(serializers.ModelSerializer):
    message_count = serializers.IntegerField(read_only=True, default=0)
    channel_count = serializers.IntegerField(read_only=True, default=0)

    class Meta:
        model = User
        fields = [
            'id', 'username', 'email', 'first_name', 'last_name',
            'avatar', 'phone_number', 'is_active', 'is_verified',
            'is_staff', 'is_superuser', 'is_online', 'last_seen',
            'date_joined', 'message_count', 'channel_count',
        ]
        read_only_fields = ['id', 'date_joined', 'last_seen']


class AdminUserDetailSerializer(serializers.ModelSerializer):
    message_count = serializers.SerializerMethodField()
    call_count = serializers.SerializerMethodField()
    channel_count = serializers.SerializerMethodField()
    device_count = serializers.SerializerMethodField()
    conversations = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = [
            'id', 'username', 'email', 'first_name', 'last_name',
            'avatar', 'phone_number', 'is_active', 'is_verified',
            'is_staff', 'is_superuser', 'is_online', 'last_seen',
            'date_joined',
            'message_count', 'call_count', 'channel_count',
            'device_count', 'conversations',
        ]
        read_only_fields = ['id', 'date_joined', 'last_seen']

    def get_message_count(self, obj):
        try:
            from chat.models import Message
            return Message.objects.filter(sender=obj, is_deleted=False).count()
        except Exception:
            return 0

    def get_call_count(self, obj):
        try:
            from calls.models import Call
            return Call.objects.filter(initiated_by=obj).count()
        except Exception:
            return 0

    def get_channel_count(self, obj):
        try:
            from channels_pub.models import ChannelMember
            return ChannelMember.objects.filter(user=obj, is_banned=False).count()
        except Exception:
            return 0

    def get_device_count(self, obj):
        try:
            from notifications.models import DeviceToken
            return DeviceToken.objects.filter(user=obj, is_active=True).count()
        except Exception:
            return 0

    def get_conversations(self, obj):
        try:
            from chat.models import ConversationParticipant
            return list(
                ConversationParticipant.objects.filter(user=obj)
                .values('conversation_id', 'conversation__conv_type', 'role', 'joined_at')[:20]
            )
        except Exception:
            return []


class AdminUserUpdateSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = [
            'first_name', 'last_name', 'email', 'phone_number',
            'is_active', 'is_verified', 'is_staff', 'is_superuser',
        ]


class AdminUserActionSerializer(serializers.Serializer):
    action = serializers.ChoiceField(choices=[
        'activate', 'deactivate', 'verify', 'unverify',
        'make_staff', 'remove_staff', 'make_superuser', 'remove_superuser',
        'force_logout',
    ])


# ────────────────────────── Conversations ──────────────────────────

class AdminConversationListSerializer(serializers.Serializer):
    id = serializers.UUIDField()
    conv_type = serializers.CharField()
    name = serializers.CharField(allow_null=True, allow_blank=True)
    participant_count = serializers.IntegerField()
    message_count = serializers.IntegerField()
    last_message_at = serializers.DateTimeField(allow_null=True)
    created_at = serializers.DateTimeField()


class AdminConversationDetailSerializer(serializers.Serializer):
    id = serializers.UUIDField()
    conv_type = serializers.CharField()
    name = serializers.CharField(allow_null=True, allow_blank=True)
    created_at = serializers.DateTimeField()
    participants = serializers.ListField()
    recent_messages = serializers.ListField()
    message_count = serializers.IntegerField()


# ────────────────────────── Channels ──────────────────────────

class AdminChannelListSerializer(serializers.Serializer):
    id = serializers.UUIDField()
    name = serializers.CharField()
    username = serializers.CharField()
    channel_type = serializers.CharField()
    owner_username = serializers.CharField()
    subscriber_count = serializers.IntegerField()
    post_count = serializers.IntegerField(default=0)
    is_active = serializers.BooleanField()
    is_verified = serializers.BooleanField()
    created_at = serializers.DateTimeField()


class AdminChannelActionSerializer(serializers.Serializer):
    action = serializers.ChoiceField(choices=[
        'verify', 'unverify', 'activate', 'deactivate',
    ])


# ────────────────────────── Calls ──────────────────────────

class AdminCallListSerializer(serializers.Serializer):
    id = serializers.UUIDField()
    caller_username = serializers.CharField()
    call_type = serializers.CharField()
    status = serializers.CharField()
    started_at = serializers.DateTimeField(allow_null=True)
    ended_at = serializers.DateTimeField(allow_null=True)
    duration = serializers.IntegerField(allow_null=True)
    participant_count = serializers.IntegerField(default=0)


# ────────────────────────── Security ──────────────────────────

class AdminThreatListSerializer(serializers.Serializer):
    id = serializers.UUIDField()
    user_username = serializers.CharField()
    threat_type = serializers.CharField()
    risk_level = serializers.CharField()
    is_resolved = serializers.BooleanField()
    detected_at = serializers.DateTimeField()
    resolved_at = serializers.DateTimeField(allow_null=True)


class AdminNetworkAnomalySerializer(serializers.Serializer):
    id = serializers.UUIDField()
    user_username = serializers.CharField()
    anomaly_type = serializers.CharField()
    severity = serializers.CharField()
    source_ip = serializers.CharField()
    detected_at = serializers.DateTimeField()


# ────────────────────────── Broadcast Notification ──────────────────────────

class AdminBroadcastNotificationSerializer(serializers.Serializer):
    title = serializers.CharField(max_length=255)
    body = serializers.CharField(max_length=1000)
    target = serializers.ChoiceField(choices=[
        'all', 'active', 'staff', 'verified',
    ], default='all')


# ────────────────────────── Dashboard ──────────────────────────

class DashboardStatsSerializer(serializers.Serializer):
    total_users = serializers.IntegerField()
    active_users_7d = serializers.IntegerField()
    online_users = serializers.IntegerField()
    total_messages = serializers.IntegerField()
    total_conversations = serializers.IntegerField()
    total_channels = serializers.IntegerField()
    total_calls = serializers.IntegerField()
    total_threats = serializers.IntegerField()
    unresolved_threats = serializers.IntegerField()


class DailyStatSerializer(serializers.Serializer):
    date = serializers.DateField()
    count = serializers.IntegerField()


# ────────────────────────── Channel Categories ──────────────────────────

class AdminChannelCategorySerializer(serializers.Serializer):
    id = serializers.IntegerField(read_only=True)
    name = serializers.CharField(max_length=100)
    slug = serializers.SlugField(max_length=100)
    icon = serializers.CharField(max_length=50, required=False, allow_blank=True)
    order = serializers.IntegerField(default=0)
