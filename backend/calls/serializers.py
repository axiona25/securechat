from rest_framework import serializers
from .models import Call, CallParticipant, ICEServer
from accounts.serializers import UserPublicSerializer


class CallParticipantSerializer(serializers.ModelSerializer):
    user = UserPublicSerializer(read_only=True)

    class Meta:
        model = CallParticipant
        fields = ['user', 'joined_at', 'left_at', 'is_muted', 'is_video_off']


class CallSerializer(serializers.ModelSerializer):
    initiated_by = UserPublicSerializer(read_only=True)
    participants = CallParticipantSerializer(many=True, read_only=True)
    direction = serializers.SerializerMethodField()

    class Meta:
        model = Call
        fields = [
            'id', 'conversation', 'call_type', 'status', 'initiated_by',
            'is_group_call', 'participants', 'direction',
            'created_at', 'started_at', 'ended_at', 'duration',
        ]

    def get_direction(self, obj):
        request = self.context.get('request')
        if request and request.user:
            if obj.initiated_by_id == request.user.id:
                return 'outgoing'
            return 'incoming'
        return None


class CallLogSerializer(serializers.ModelSerializer):
    """Simplified serializer for call log list"""
    initiated_by = UserPublicSerializer(read_only=True)
    other_party = serializers.SerializerMethodField()
    direction = serializers.SerializerMethodField()

    class Meta:
        model = Call
        fields = [
            'id', 'call_type', 'status', 'initiated_by', 'other_party',
            'direction', 'is_group_call', 'duration', 'created_at',
        ]

    def get_other_party(self, obj):
        request = self.context.get('request')
        if request and request.user:
            other = obj.participants.exclude(user=request.user).select_related('user').first()
            if other:
                return UserPublicSerializer(other.user).data
        return None

    def get_direction(self, obj):
        request = self.context.get('request')
        if request and request.user:
            return 'outgoing' if obj.initiated_by_id == request.user.id else 'incoming'
        return None
