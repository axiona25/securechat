from rest_framework import generics, status, permissions
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.throttling import UserRateThrottle
from django.shortcuts import get_object_or_404
from django.db.models import Sum, Count

from .models import (
    TranslationPreference, ConversationTranslationSetting,
    InstalledLanguagePack, TranslationUsageLog, TranslationCache,
)
from .serializers import (
    TranslationPreferenceSerializer, ConversationTranslationSettingSerializer,
    TranslateMessageSerializer, TranslateTextSerializer, TranslateBatchSerializer,
    TranslationResultSerializer, LanguageSerializer, LanguagePairSerializer,
    InstalledLanguagePackSerializer, InstallPackageSerializer,
    TranslationStatsSerializer,
)
from . import engine


class TranslationRateThrottle(UserRateThrottle):
    rate = '100/hour'


# ────────────────────────── Preferences ──────────────────────────

class TranslationPreferenceView(APIView):
    """
    GET  /api/translation/preferences/ — get translation preferences
    PATCH /api/translation/preferences/ — update preferences
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        prefs, _ = TranslationPreference.objects.get_or_create(user=request.user)
        serializer = TranslationPreferenceSerializer(prefs)
        return Response(serializer.data)

    def patch(self, request):
        prefs, _ = TranslationPreference.objects.get_or_create(user=request.user)
        serializer = TranslationPreferenceSerializer(prefs, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)


class ConversationTranslationSettingView(APIView):
    """
    POST /api/translation/conversations/
    Set auto-translate for a specific conversation.
    Body: { "conversation_id": "uuid", "auto_translate": true }
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        serializer = ConversationTranslationSettingSerializer(
            data=request.data, context={'request': request}
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data, status=status.HTTP_200_OK)

    def get(self, request):
        settings_qs = ConversationTranslationSetting.objects.filter(user=request.user)
        serializer = ConversationTranslationSettingSerializer(settings_qs, many=True)
        return Response(serializer.data)


class ConversationTranslationSettingDeleteView(APIView):
    """
    DELETE /api/translation/conversations/<conversation_id>/
    Remove auto-translate setting for a conversation (revert to global setting).
    """
    permission_classes = [permissions.IsAuthenticated]

    def delete(self, request, conversation_id):
        deleted, _ = ConversationTranslationSetting.objects.filter(
            user=request.user, conversation_id=conversation_id
        ).delete()
        if deleted:
            return Response({'detail': 'Setting removed.'})
        return Response({'detail': 'Setting not found.'}, status=status.HTTP_404_NOT_FOUND)


# ────────────────────────── Translation ──────────────────────────

def _get_message_text(message):
    """Get translatable text from a chat Message (content_for_translation)."""
    return getattr(message, 'content_for_translation', '') or ''


class TranslateMessageView(APIView):
    """
    POST /api/translation/translate/message/
    Translate a single chat message.
    Body: { "message_id": "uuid", "target_language": "it" }
    """
    permission_classes = [permissions.IsAuthenticated]
    throttle_classes = [TranslationRateThrottle]

    def post(self, request):
        serializer = TranslateMessageSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        from chat.models import Message
        message = get_object_or_404(Message, id=data['message_id'])

        target_lang = data.get('target_language', '')
        if not target_lang:
            prefs, _ = TranslationPreference.objects.get_or_create(user=request.user)
            target_lang = prefs.preferred_language

        source_lang = data.get('source_language', '') or None

        text = _get_message_text(message)
        if not text or not text.strip():
            return Response({
                'translated_text': '',
                'source_language': source_lang or '',
                'target_language': target_lang,
                'detected_language': '',
                'cached': False,
                'char_count': 0,
            })

        result = engine.translate_text(
            text=text,
            target_lang=target_lang,
            source_lang=source_lang,
            user_id=request.user.id,
        )

        return Response(result)


class TranslateTextView(APIView):
    """
    POST /api/translation/translate/text/
    Translate arbitrary text (for previews, drafts, etc.).
    Body: { "text": "Hello world", "target_language": "it" }
    """
    permission_classes = [permissions.IsAuthenticated]
    throttle_classes = [TranslationRateThrottle]

    def post(self, request):
        serializer = TranslateTextSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        result = engine.translate_text(
            text=data['text'],
            target_lang=data['target_language'],
            source_lang=data.get('source_language', '') or None,
            user_id=request.user.id,
        )

        return Response(result)


class TranslateBatchView(APIView):
    """
    POST /api/translation/translate/batch/
    Translate the last N messages of a conversation.
    Body: { "conversation_id": "uuid", "target_language": "it", "limit": 20 }
    """
    permission_classes = [permissions.IsAuthenticated]
    throttle_classes = [TranslationRateThrottle]

    def post(self, request):
        serializer = TranslateBatchSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        from chat.models import Message, ConversationParticipant

        conversation_id = data['conversation_id']

        is_participant = ConversationParticipant.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()
        if not is_participant:
            return Response(
                {'error': 'You are not a participant of this conversation.'},
                status=status.HTTP_403_FORBIDDEN
            )

        target_lang = data.get('target_language', '')
        if not target_lang:
            prefs, _ = TranslationPreference.objects.get_or_create(user=request.user)
            target_lang = prefs.preferred_language

        limit = data.get('limit', 20)

        messages = Message.objects.filter(
            conversation_id=conversation_id,
        ).exclude(
            content_for_translation='',
        ).exclude(
            content_for_translation__isnull=True,
        ).order_by('-created_at')[:limit]

        results = []
        for msg in messages:
            text = _get_message_text(msg)
            if not text.strip():
                continue
            result = engine.translate_text(
                text=text,
                target_lang=target_lang,
                source_lang=None,
                user_id=request.user.id,
            )
            result['message_id'] = str(msg.id)
            result['original_text'] = text
            results.append(result)

        return Response({
            'conversation_id': str(conversation_id),
            'target_language': target_lang,
            'translations': results,
            'count': len(results),
        })


# ────────────────────────── Language Detection ──────────────────────────

class DetectLanguageView(APIView):
    """
    POST /api/translation/detect/
    Detect language of given text.
    Body: { "text": "Ciao come stai?" }
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        text = request.data.get('text', '')
        if not text.strip():
            return Response({'error': 'text is required.'}, status=status.HTTP_400_BAD_REQUEST)

        detected = engine.detect_language(text)
        return Response({
            'detected_language': detected,
            'text': text[:100],
        })


# ────────────────────────── Languages ──────────────────────────

class InstalledLanguagesView(APIView):
    """
    GET /api/translation/languages/
    List installed languages available for translation.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        languages = engine.get_installed_languages()
        return Response({
            'languages': languages,
            'count': len(languages),
        })


class InstalledPairsView(APIView):
    """
    GET /api/translation/languages/pairs/
    List installed translation pairs.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        pairs = engine.get_installed_pairs()
        return Response({
            'pairs': pairs,
            'count': len(pairs),
        })


class CheckPairView(APIView):
    """
    GET /api/translation/languages/check/?source=en&target=it
    Check if a translation pair is available (including via pivot).
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        source = request.query_params.get('source', '')
        target = request.query_params.get('target', '')
        if not source or not target:
            return Response(
                {'error': 'source and target query params required.'},
                status=status.HTTP_400_BAD_REQUEST
            )
        available = engine.can_translate(source, target)
        direct = engine.is_pair_installed(source, target)
        return Response({
            'source': source,
            'target': target,
            'available': available,
            'direct': direct,
            'pivot': available and not direct,
        })


# ────────────────────────── Language Pack Management (Admin) ──────────────────────────

class AvailablePackagesView(APIView):
    """
    GET /api/translation/packages/available/
    List all downloadable Argos Translate packages.
    Admin only.
    """
    permission_classes = [permissions.IsAdminUser]

    def get(self, request):
        packages = engine.get_available_packages()
        return Response({
            'packages': packages,
            'count': len(packages),
        })


class InstalledPackagesView(generics.ListAPIView):
    """
    GET /api/translation/packages/installed/
    List installed language packs from DB.
    """
    serializer_class = InstalledLanguagePackSerializer
    permission_classes = [permissions.IsAuthenticated]
    pagination_class = None
    queryset = InstalledLanguagePack.objects.all().order_by('source_language', 'target_language')


class InstallPackageView(APIView):
    """
    POST /api/translation/packages/install/
    Install a language pack. Admin only.
    Body: { "from_code": "en", "to_code": "it" }
    This dispatches a Celery task (download can take a while).
    """
    permission_classes = [permissions.IsAdminUser]

    def post(self, request):
        serializer = InstallPackageSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        from .tasks import install_language_pack_task
        install_language_pack_task.delay(data['from_code'], data['to_code'])

        return Response({
            'detail': f'Installation of {data["from_code"]}→{data["to_code"]} started. '
                      'This may take a few minutes.',
            'status': 'pending',
        }, status=status.HTTP_202_ACCEPTED)


# ────────────────────────── Stats ──────────────────────────

class TranslationStatsView(APIView):
    """
    GET /api/translation/stats/
    Translation usage statistics. Admin only.
    """
    permission_classes = [permissions.IsAdminUser]

    def get(self, request):
        logs = TranslationUsageLog.objects.all()
        total = logs.count()
        total_chars = logs.aggregate(total=Sum('char_count'))['total'] or 0
        cached = logs.filter(cached=True).count()
        cache_hit_rate = round((cached / total * 100), 1) if total > 0 else 0.0

        top_pairs = list(
            logs.values('source_language', 'target_language')
            .annotate(
                count=Count('id'),
                chars=Sum('char_count'),
            )
            .order_by('-count')[:10]
        )

        installed_count = InstalledLanguagePack.objects.count()

        return Response({
            'total_translations': total,
            'total_chars': total_chars,
            'cached_translations': cached,
            'cache_hit_rate': cache_hit_rate,
            'top_language_pairs': top_pairs,
            'installed_packs_count': installed_count,
        })


class MyTranslationStatsView(APIView):
    """
    GET /api/translation/stats/me/
    Translation stats for the current user.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        logs = TranslationUsageLog.objects.filter(user=request.user)
        total = logs.count()
        total_chars = logs.aggregate(total=Sum('char_count'))['total'] or 0
        cached = logs.filter(cached=True).count()

        return Response({
            'total_translations': total,
            'total_chars': total_chars,
            'cached_translations': cached,
        })
