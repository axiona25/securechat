from django.contrib import admin
from .models import (
    TranslationPreference, ConversationTranslationSetting,
    TranslationCache, InstalledLanguagePack, TranslationUsageLog,
)


@admin.register(TranslationPreference)
class TranslationPreferenceAdmin(admin.ModelAdmin):
    list_display = ['user', 'preferred_language', 'auto_translate', 'updated_at']
    list_filter = ['preferred_language', 'auto_translate']
    search_fields = ['user__username']
    raw_id_fields = ['user']


@admin.register(ConversationTranslationSetting)
class ConversationTranslationSettingAdmin(admin.ModelAdmin):
    list_display = ['user', 'conversation_id', 'auto_translate', 'created_at']
    list_filter = ['auto_translate']
    search_fields = ['user__username']
    raw_id_fields = ['user']


@admin.register(TranslationCache)
class TranslationCacheAdmin(admin.ModelAdmin):
    list_display = ['source_language', 'target_language', 'source_short', 'translated_short', 'hit_count', 'created_at']
    list_filter = ['source_language', 'target_language']
    search_fields = ['source_text', 'translated_text']
    readonly_fields = ['id', 'cache_key', 'created_at']

    def source_short(self, obj):
        return obj.source_text[:60] + '...' if len(obj.source_text) > 60 else obj.source_text
    source_short.short_description = 'Source'

    def translated_short(self, obj):
        return obj.translated_text[:60] + '...' if len(obj.translated_text) > 60 else obj.translated_text
    translated_short.short_description = 'Translation'


@admin.register(InstalledLanguagePack)
class InstalledLanguagePackAdmin(admin.ModelAdmin):
    list_display = ['source_language_name', 'source_language', 'target_language_name', 'target_language', 'package_version', 'installed_at']
    list_filter = ['source_language', 'target_language']
    readonly_fields = ['id', 'installed_at']


@admin.register(TranslationUsageLog)
class TranslationUsageLogAdmin(admin.ModelAdmin):
    list_display = ['user', 'source_language', 'target_language', 'char_count', 'cached', 'created_at']
    list_filter = ['source_language', 'target_language', 'cached']
    search_fields = ['user__username']
    raw_id_fields = ['user']
    date_hierarchy = 'created_at'
    readonly_fields = ['id', 'created_at']
