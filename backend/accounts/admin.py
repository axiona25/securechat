from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User, EmailVerificationToken, PasswordResetToken


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = ['email', 'username', 'first_name', 'last_name', 'is_verified', 'is_online', 'country', 'language', 'created_at']
    list_filter = ['is_verified', 'is_online', 'is_staff', 'country', 'language']
    search_fields = ['email', 'username', 'first_name', 'last_name', 'phone_number']
    ordering = ['-created_at']

    fieldsets = BaseUserAdmin.fieldsets + (
        ('SecureChat Profile', {
            'fields': ('phone_number', 'avatar', 'bio', 'country', 'language', 'is_verified',
                       'is_online', 'last_seen', 'firebase_token', 'public_key')
        }),
        ('Settings', {
            'fields': ('theme', 'chat_wallpaper', 'notification_enabled', 'read_receipts', 'last_seen_visible')
        }),
    )

    add_fieldsets = BaseUserAdmin.add_fieldsets + (
        ('SecureChat Profile', {
            'fields': ('email', 'first_name', 'last_name', 'phone_number', 'country', 'language')
        }),
    )


@admin.register(EmailVerificationToken)
class EmailVerificationTokenAdmin(admin.ModelAdmin):
    list_display = ['user', 'code', 'created_at', 'expires_at', 'is_used']
    list_filter = ['is_used']
    search_fields = ['user__email']


@admin.register(PasswordResetToken)
class PasswordResetTokenAdmin(admin.ModelAdmin):
    list_display = ['user', 'token', 'created_at', 'expires_at', 'is_used']
    list_filter = ['is_used']
    search_fields = ['user__email']
