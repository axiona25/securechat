from django.contrib import admin
from .models import Call, CallParticipant, ICEServer


@admin.register(Call)
class CallAdmin(admin.ModelAdmin):
    list_display = ['id', 'call_type', 'status', 'initiated_by', 'is_group_call', 
                    'duration', 'created_at', 'started_at', 'ended_at']
    list_filter = ['call_type', 'status', 'is_group_call']
    search_fields = ['initiated_by__email']
    readonly_fields = ['id', 'created_at']


@admin.register(CallParticipant)
class CallParticipantAdmin(admin.ModelAdmin):
    list_display = ['call', 'user', 'joined_at', 'left_at', 'is_muted', 'is_video_off']
    search_fields = ['user__email']


@admin.register(ICEServer)
class ICEServerAdmin(admin.ModelAdmin):
    list_display = ['server_type', 'url', 'is_active', 'priority', 'created_at']
    list_filter = ['server_type', 'is_active']
    list_editable = ['is_active', 'priority']
