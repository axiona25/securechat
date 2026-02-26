from django.contrib import admin
from .models import (
    Conversation, ConversationParticipant, Message, Attachment,
    MessageStatus, MessageReaction, LocationShare, ContactShare,
    CalendarEvent, Group, Story, StoryView
)


@admin.register(Conversation)
class ConversationAdmin(admin.ModelAdmin):
    list_display = ['id', 'conv_type', 'is_locked', 'created_at', 'updated_at']
    list_filter = ['conv_type', 'is_locked']


@admin.register(ConversationParticipant)
class ConversationParticipantAdmin(admin.ModelAdmin):
    list_display = ['conversation', 'user', 'role', 'unread_count', 'joined_at']
    list_filter = ['role']
    search_fields = ['user__email']


@admin.register(Message)
class MessageAdmin(admin.ModelAdmin):
    list_display = ['id', 'conversation', 'sender', 'message_type', 'is_deleted', 'created_at']
    list_filter = ['message_type', 'is_deleted']
    search_fields = ['sender__email']


@admin.register(Attachment)
class AttachmentAdmin(admin.ModelAdmin):
    list_display = ['id', 'message', 'file_name', 'file_size', 'mime_type']


@admin.register(MessageStatus)
class MessageStatusAdmin(admin.ModelAdmin):
    list_display = ['message', 'user', 'status', 'timestamp']
    list_filter = ['status']


@admin.register(MessageReaction)
class MessageReactionAdmin(admin.ModelAdmin):
    list_display = ['message', 'user', 'emoji', 'created_at']


@admin.register(Group)
class GroupAdmin(admin.ModelAdmin):
    list_display = ['name', 'conversation', 'created_by', 'max_members', 'created_at']
    search_fields = ['name']


@admin.register(Story)
class StoryAdmin(admin.ModelAdmin):
    list_display = ['user', 'story_type', 'privacy', 'is_active', 'created_at', 'expires_at']
    list_filter = ['story_type', 'is_active', 'privacy']


@admin.register(LocationShare)
class LocationShareAdmin(admin.ModelAdmin):
    list_display = ['message', 'latitude', 'longitude', 'is_live']


@admin.register(CalendarEvent)
class CalendarEventAdmin(admin.ModelAdmin):
    list_display = ['title', 'start_datetime', 'end_datetime', 'location']


@admin.register(ContactShare)
class ContactShareAdmin(admin.ModelAdmin):
    list_display = ['contact_name', 'contact_phone', 'contact_email']


@admin.register(StoryView)
class StoryViewAdmin(admin.ModelAdmin):
    list_display = ['story', 'viewer', 'viewed_at']
