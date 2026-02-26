from django.contrib import admin
from .models import UserKeyBundle, OneTimePreKey, SessionKey, KeyBundleFetchLog, SecurityAlert


@admin.register(UserKeyBundle)
class UserKeyBundleAdmin(admin.ModelAdmin):
    list_display = ['user', 'signed_prekey_id', 'signed_prekey_created_at', 'uploaded_at']
    search_fields = ['user__email']
    readonly_fields = ['identity_key_public', 'identity_dh_public', 'signed_prekey_public', 
                       'signed_prekey_signature']


@admin.register(OneTimePreKey)
class OneTimePreKeyAdmin(admin.ModelAdmin):
    list_display = ['user', 'key_id', 'is_used', 'used_by', 'created_at', 'used_at']
    list_filter = ['is_used']
    search_fields = ['user__email']


@admin.register(SessionKey)
class SessionKeyAdmin(admin.ModelAdmin):
    list_display = ['user', 'peer', 'session_version', 'created_at', 'updated_at']
    search_fields = ['user__email', 'peer__email']


@admin.register(KeyBundleFetchLog)
class KeyBundleFetchLogAdmin(admin.ModelAdmin):
    list_display = ['requester', 'target_user', 'ip_address', 'fetched_at']
    list_filter = ['fetched_at']
    search_fields = ['requester__email', 'target_user__email']
    readonly_fields = ['requester', 'target_user', 'ip_address', 'user_agent', 'fetched_at']


@admin.register(SecurityAlert)
class SecurityAlertAdmin(admin.ModelAdmin):
    list_display = ['user', 'alert_type', 'severity', 'is_resolved', 'created_at']
    list_filter = ['alert_type', 'severity', 'is_resolved']
    search_fields = ['user__email', 'message']
