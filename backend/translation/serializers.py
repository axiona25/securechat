from rest_framework import serializers
from .models import (
    TranslationPreference, ConversationTranslationSetting,
    TranslationCache, InstalledLanguagePack, TranslationUsageLog,
)


class TranslationPreferenceSerializer(serializers.ModelSerializer):
    class Meta:
        model = TranslationPreference
        fields = [
            'preferred_language', 'auto_translate',
            'created_at', 'updated_at',
        ]
        read_only_fields = ['created_at', 'updated_at']


class ConversationTranslationSettingSerializer(serializers.ModelSerializer):
    class Meta:
        model = ConversationTranslationSetting
        fields = ['id', 'conversation_id', 'auto_translate', 'created_at']
        read_only_fields = ['id', 'created_at']

    def create(self, validated_data):
        user = self.context['request'].user
        setting, _ = ConversationTranslationSetting.objects.update_or_create(
            user=user,
            conversation_id=validated_data['conversation_id'],
            defaults={'auto_translate': validated_data.get('auto_translate', True)},
        )
        return setting


class TranslateMessageSerializer(serializers.Serializer):
    message_id = serializers.UUIDField(help_text='UUID of the chat.Message to translate')
    target_language = serializers.CharField(
        max_length=10, required=False,
        help_text='Target language code. If omitted, uses user preference.'
    )
    source_language = serializers.CharField(
        max_length=10, required=False, allow_blank=True,
        help_text='Source language code. If omitted, auto-detect.'
    )


class TranslateTextSerializer(serializers.Serializer):
    text = serializers.CharField(max_length=5000)
    target_language = serializers.CharField(max_length=10)
    source_language = serializers.CharField(max_length=10, required=False, allow_blank=True)


class TranslateBatchSerializer(serializers.Serializer):
    conversation_id = serializers.UUIDField()
    target_language = serializers.CharField(
        max_length=10, required=False,
        help_text='Target language code. If omitted, uses user preference.'
    )
    limit = serializers.IntegerField(min_value=1, max_value=50, default=20)


class TranslationResultSerializer(serializers.Serializer):
    translated_text = serializers.CharField()
    source_language = serializers.CharField()
    target_language = serializers.CharField()
    detected_language = serializers.CharField(allow_blank=True)
    cached = serializers.BooleanField()
    char_count = serializers.IntegerField()
    error = serializers.CharField(required=False, allow_blank=True)


class LanguageSerializer(serializers.Serializer):
    code = serializers.CharField()
    name = serializers.CharField()


class LanguagePairSerializer(serializers.Serializer):
    source = serializers.CharField()
    source_name = serializers.CharField()
    target = serializers.CharField()
    target_name = serializers.CharField()


class InstalledLanguagePackSerializer(serializers.ModelSerializer):
    class Meta:
        model = InstalledLanguagePack
        fields = [
            'id', 'source_language', 'source_language_name',
            'target_language', 'target_language_name',
            'package_version', 'installed_at',
        ]
        read_only_fields = ['id', 'installed_at']


class InstallPackageSerializer(serializers.Serializer):
    from_code = serializers.CharField(max_length=10)
    to_code = serializers.CharField(max_length=10)


class TranslationStatsSerializer(serializers.Serializer):
    total_translations = serializers.IntegerField()
    total_chars = serializers.IntegerField()
    cached_translations = serializers.IntegerField()
    cache_hit_rate = serializers.FloatField()
    top_language_pairs = serializers.ListField()
    installed_packs_count = serializers.IntegerField()
