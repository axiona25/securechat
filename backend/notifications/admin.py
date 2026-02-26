from django.contrib import admin
from .models import DeviceToken, NotificationPreference, MuteRule, Notification


@admin.register(DeviceToken)
class DeviceTokenAdmin(admin.ModelAdmin):
    list_display = ['user', 'platform', 'device_id_short', 'device_name', 'is_active', 'last_used_at', 'created_at']
    list_filter = ['platform', 'is_active']
    search_fields = ['user__username', 'device_id', 'device_name']
    raw_id_fields = ['user']
    readonly_fields = ['id', 'created_at', 'last_used_at']

    def device_id_short(self, obj):
        return obj.device_id[:30] + '...' if len(obj.device_id) > 30 else obj.device_id
    device_id_short.short_description = 'Device ID'


@admin.register(NotificationPreference)
class NotificationPreferenceAdmin(admin.ModelAdmin):
    list_display = [
        'user', 'new_message', 'incoming_call', 'channel_post',
        'dnd_enabled', 'sound_enabled', 'show_preview', 'updated_at',
    ]
    list_filter = ['dnd_enabled', 'sound_enabled']
    search_fields = ['user__username']
    raw_id_fields = ['user']


@admin.register(MuteRule)
class MuteRuleAdmin(admin.ModelAdmin):
    list_display = ['user', 'target_type', 'target_id_short', 'muted_until', 'is_active_display', 'created_at']
    list_filter = ['target_type']
    search_fields = ['user__username', 'target_id']
    raw_id_fields = ['user']

    def target_id_short(self, obj):
        return str(obj.target_id)[:20]
    target_id_short.short_description = 'Target ID'

    def is_active_display(self, obj):
        return obj.is_active
    is_active_display.boolean = True
    is_active_display.short_description = 'Active'


@admin.register(Notification)
class NotificationAdmin(admin.ModelAdmin):
    list_display = [
        'recipient', 'notification_type', 'title_short', 'sender',
        'is_read', 'fcm_sent', 'created_at',
    ]
    list_filter = ['notification_type', 'is_read', 'fcm_sent']
    search_fields = ['recipient__username', 'sender__username', 'title', 'body']
    raw_id_fields = ['recipient', 'sender']
    readonly_fields = ['id', 'created_at', 'read_at', 'fcm_message_id', 'fcm_error']
    date_hierarchy = 'created_at'

    def title_short(self, obj):
        return obj.title[:60] + '...' if len(obj.title) > 60 else obj.title
    title_short.short_description = 'Title'
