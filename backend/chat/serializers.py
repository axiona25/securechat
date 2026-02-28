from rest_framework import serializers
from .models import (
    Conversation, ConversationParticipant, Message, Attachment,
    MessageStatus, MessageReaction, LocationShare, ContactShare,
    CalendarEvent, Group, Story, StoryView
)
from accounts.serializers import UserPublicSerializer
import base64


class AttachmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Attachment
        fields = ['id', 'file', 'file_name', 'file_size', 'mime_type',
                  'thumbnail', 'duration', 'width', 'height',
                  'is_encrypted', 'file_hash', 'created_at']
        read_only_fields = ['id', 'created_at']


class MessageStatusSerializer(serializers.ModelSerializer):
    class Meta:
        model = MessageStatus
        fields = ['user', 'status', 'timestamp']


class ReactionSerializer(serializers.ModelSerializer):
    class Meta:
        model = MessageReaction
        fields = ['user', 'emoji', 'created_at']


class LocationShareSerializer(serializers.ModelSerializer):
    class Meta:
        model = LocationShare
        fields = ['latitude', 'longitude', 'address', 'is_live', 'live_until', 'last_updated']


class ContactShareSerializer(serializers.ModelSerializer):
    class Meta:
        model = ContactShare
        fields = ['contact_name', 'contact_phone', 'contact_email', 'vcard_data']


class CalendarEventSerializer(serializers.ModelSerializer):
    class Meta:
        model = CalendarEvent
        fields = ['title', 'description', 'start_datetime', 'end_datetime',
                  'location', 'ics_file', 'created_at']


class MessageSerializer(serializers.ModelSerializer):
    sender = UserPublicSerializer(read_only=True)
    attachments = AttachmentSerializer(many=True, read_only=True)
    statuses = MessageStatusSerializer(many=True, read_only=True)
    reactions = ReactionSerializer(many=True, read_only=True)
    location = LocationShareSerializer(read_only=True)
    shared_contact = ContactShareSerializer(read_only=True)
    calendar_event = CalendarEventSerializer(read_only=True)
    content = serializers.SerializerMethodField()
    content_encrypted_b64 = serializers.SerializerMethodField()
    reply_to_preview = serializers.SerializerMethodField()

    class Meta:
        model = Message
        fields = [
            'id', 'conversation', 'sender', 'message_type',
            'content', 'content_encrypted_b64', 'reply_to', 'reply_to_preview',
            'is_forwarded', 'is_deleted', 'is_edited', 'edited_at',
            'attachments', 'statuses', 'reactions',
            'location', 'shared_contact', 'calendar_event',
            'created_at',
        ]
        read_only_fields = ['id', 'sender', 'created_at']

    def get_content(self, obj):
        """Return plaintext content if available, empty string if E2E encrypted."""
        if obj.is_deleted:
            return ''
        # Per E2E gruppi: restituisci il payload cifrato specifico per l'utente corrente
        request = self.context.get('request')
        if request and hasattr(request, 'user') and request.user.is_authenticated:
            from chat.models import MessageRecipient
            recipient = MessageRecipient.objects.filter(
                message=obj, user=request.user
            ).first()
            if recipient:
                return '🔒 Messaggio cifrato'
        if not obj.content_encrypted:
            return ''
        if obj.content_for_translation:
            return obj.content_for_translation
        try:
            decoded = bytes(obj.content_encrypted).decode('utf-8')
            if decoded.isprintable() or all(
                c.isprintable() or c in '\n\r\t' for c in decoded
            ):
                return decoded
        except (UnicodeDecodeError, ValueError):
            pass
        return ''

    def get_content_encrypted_b64(self, obj):
        """Restituisce il payload cifrato specifico per l'utente corrente (E2E gruppi)."""
        if obj.is_deleted:
            return None
        request = self.context.get('request')
        if request and hasattr(request, 'user') and request.user.is_authenticated:
            from chat.models import MessageRecipient
            recipient = MessageRecipient.objects.filter(
                message=obj, user=request.user
            ).first()
            if recipient:
                return base64.b64encode(bytes(recipient.content_encrypted)).decode('utf-8')
        # Fallback: restituisci content_encrypted del messaggio se presente
        if obj.content_encrypted:
            try:
                return base64.b64encode(bytes(obj.content_encrypted)).decode('utf-8')
            except Exception:
                pass
        return None

    def get_reply_to_preview(self, obj):
        if obj.reply_to and not obj.reply_to.is_deleted:
            return {
                'id': str(obj.reply_to.id),
                'sender_name': f'{obj.reply_to.sender.first_name} {obj.reply_to.sender.last_name}',
                'message_type': obj.reply_to.message_type,
            }
        return None


class ParticipantSerializer(serializers.ModelSerializer):
    user = UserPublicSerializer(read_only=True)

    class Meta:
        model = ConversationParticipant
        fields = ['user', 'role', 'joined_at', 'muted_until', 'is_pinned', 'unread_count']


class ConversationListSerializer(serializers.ModelSerializer):
    last_message = serializers.SerializerMethodField()
    participants_info = serializers.SerializerMethodField()
    unread_count = serializers.SerializerMethodField()
    is_pinned = serializers.SerializerMethodField()
    is_muted = serializers.SerializerMethodField()
    is_locked = serializers.SerializerMethodField()
    is_favorite = serializers.SerializerMethodField()
    group_name = serializers.SerializerMethodField()
    group_avatar = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            'id', 'conv_type', 'last_message', 'participants_info',
            'unread_count', 'is_pinned', 'is_muted', 'is_locked', 'is_favorite',
            'group_name', 'group_avatar',
            'created_at', 'updated_at',
        ]

    def get_last_message(self, obj):
        request = self.context.get('request')
        user = request.user if request else None
        if user is None:
            return None
        participant = obj.conversation_participants.filter(user=user).first()
        cleared_at = participant.cleared_at if participant else None
        qs = obj.messages.filter(is_deleted=False)
        if cleared_at:
            qs = qs.filter(created_at__gt=cleared_at)
        last = qs.order_by('-created_at').first()
        if last is None:
            return None
        return MessageSerializer(last, context=self.context).data

    def get_participants_info(self, obj):
        participants = obj.conversation_participants.select_related('user').all()
        return ParticipantSerializer(participants, many=True).data

    def get_unread_count(self, obj):
        user = self.context.get('request', {})
        if hasattr(user, 'user'):
            user = user.user
        try:
            p = obj.conversation_participants.get(user=user)
            return p.unread_count
        except Exception:
            return 0

    def get_is_pinned(self, obj):
        user = self.context.get('request', {})
        if hasattr(user, 'user'):
            user = user.user
        try:
            p = obj.conversation_participants.get(user=user)
            return p.is_pinned
        except Exception:
            return False

    def get_is_muted(self, obj):
        from django.utils import timezone
        user = self.context.get('request', {})
        if hasattr(user, 'user'):
            user = user.user
        try:
            p = obj.conversation_participants.get(user=user)
            return p.muted_until is not None and timezone.now() < p.muted_until
        except Exception:
            return False

    def get_is_locked(self, obj):
        request = self.context.get('request')
        if not request:
            return False
        participant = obj.conversation_participants.filter(user=request.user).first()
        return getattr(participant, 'is_locked', False)

    def get_is_favorite(self, obj):
        request = self.context.get('request')
        if not request:
            return False
        participant = obj.conversation_participants.filter(user=request.user).first()
        return getattr(participant, 'is_favorite', False)

    def get_group_name(self, obj):
        if obj.conv_type == 'group':
            group = getattr(obj, 'group_info', None)
            return group.name if group else None
        return None

    def get_group_avatar(self, obj):
        if obj.conv_type == 'group':
            group = getattr(obj, 'group_info', None)
            return group.avatar.url if group and group.avatar else None
        return None


class ConversationDetailSerializer(ConversationListSerializer):
    """Extended serializer with full participant details"""
    pass


class CreatePrivateConversationSerializer(serializers.Serializer):
    user_id = serializers.IntegerField()

    def validate_user_id(self, value):
        from django.contrib.auth import get_user_model
        User = get_user_model()
        if not User.objects.filter(id=value, is_active=True).exists():
            raise serializers.ValidationError('Utente non trovato.')
        return value


class CreateGroupSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=100)
    description = serializers.CharField(required=False, default='')
    member_ids = serializers.ListField(child=serializers.IntegerField(), min_length=1)


class SendMessageSerializer(serializers.Serializer):
    message_type = serializers.ChoiceField(choices=Message.MSG_TYPES, default='text')
    content_encrypted = serializers.CharField(required=False, default='')
    reply_to_id = serializers.UUIDField(required=False, allow_null=True)


class LockChatSerializer(serializers.Serializer):
    pin = serializers.CharField(min_length=4, max_length=20)


class StorySerializer(serializers.ModelSerializer):
    user = UserPublicSerializer(read_only=True)
    views_count = serializers.SerializerMethodField()
    has_viewed = serializers.SerializerMethodField()

    class Meta:
        model = Story
        fields = [
            'id', 'user', 'story_type', 'media', 'text_content',
            'background_color', 'font_style', 'caption',
            'privacy', 'created_at', 'expires_at', 'is_active',
            'views_count', 'has_viewed',
        ]
        read_only_fields = ['id', 'user', 'created_at', 'expires_at', 'is_active']

    def get_views_count(self, obj):
        return obj.views.count()

    def get_has_viewed(self, obj):
        request = self.context.get('request')
        if request and request.user.is_authenticated:
            return obj.views.filter(viewer=request.user).exists()
        return False
