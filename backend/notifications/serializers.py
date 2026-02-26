from rest_framework import serializers
from .models import DeviceToken, NotificationPreference, MuteRule, Notification, NotificationType


class DeviceTokenSerializer(serializers.ModelSerializer):
    class Meta:
        model = DeviceToken
        fields = ['id', 'token', 'platform', 'device_id', 'device_name', 'is_active', 'last_used_at', 'created_at']
        read_only_fields = ['id', 'is_active', 'last_used_at', 'created_at']

    def validate_platform(self, value):
        if value not in DeviceToken.Platform.values:
            raise serializers.ValidationError(
                f'Invalid platform. Choose from: {", ".join(DeviceToken.Platform.values)}'
            )
        return value

    def create(self, validated_data):
        user = self.context['request'].user
        device_id = validated_data['device_id']

        # Upsert: update token if device_id exists, otherwise create
        token_obj, created = DeviceToken.objects.update_or_create(
            user=user,
            device_id=device_id,
            defaults={
                'token': validated_data['token'],
                'platform': validated_data['platform'],
                'device_name': validated_data.get('device_name', ''),
                'is_active': True,
            }
        )
        return token_obj


class DeviceTokenDeleteSerializer(serializers.Serializer):
    device_id = serializers.CharField(max_length=255)


class NotificationPreferenceSerializer(serializers.ModelSerializer):
    class Meta:
        model = NotificationPreference
        fields = [
            'new_message', 'message_reaction', 'mention',
            'incoming_call', 'missed_call', 'channel_post',
            'group_invite', 'channel_invite', 'security_alert',
            'dnd_enabled', 'dnd_start_time', 'dnd_end_time',
            'sound_enabled', 'vibration_enabled', 'show_preview',
            'updated_at',
        ]
        read_only_fields = ['updated_at']


class MuteRuleSerializer(serializers.ModelSerializer):
    is_active = serializers.BooleanField(read_only=True)

    class Meta:
        model = MuteRule
        fields = ['id', 'target_type', 'target_id', 'muted_until', 'is_active', 'created_at']
        read_only_fields = ['id', 'created_at']

    def create(self, validated_data):
        user = self.context['request'].user
        rule, created = MuteRule.objects.update_or_create(
            user=user,
            target_type=validated_data['target_type'],
            target_id=validated_data['target_id'],
            defaults={'muted_until': validated_data.get('muted_until')},
        )
        return rule


class NotificationSerializer(serializers.ModelSerializer):
    sender_username = serializers.CharField(source='sender.username', read_only=True, default=None)

    class Meta:
        model = Notification
        fields = [
            'id', 'notification_type', 'title', 'body', 'data',
            'sender', 'sender_username',
            'source_type', 'source_id',
            'is_read', 'read_at', 'created_at',
        ]
        read_only_fields = [
            'id', 'notification_type', 'title', 'body', 'data',
            'sender', 'source_type', 'source_id', 'created_at',
        ]


class BadgeCountSerializer(serializers.Serializer):
    unread_count = serializers.IntegerField()
    by_type = serializers.DictField(child=serializers.IntegerField())
