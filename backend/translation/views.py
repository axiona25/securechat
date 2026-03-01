from rest_framework.views import APIView
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework import status
from .engine import translate_text, get_installed_languages, can_translate
import logging

logger = logging.getLogger(__name__)


class TranslateMessageView(APIView):
    """Traduce un messaggio nella lingua target."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        text = request.data.get('text', '')
        target_lang = request.data.get('target_lang', '')
        source_lang = request.data.get('source_lang', None)

        if not text or not target_lang:
            return Response({'error': 'text and target_lang required'}, status=status.HTTP_400_BAD_REQUEST)

        result = translate_text(
            text=text,
            target_lang=target_lang,
            source_lang=source_lang,
            user_id=request.user.id,
        )

        return Response(result)


class TranslateBatchView(APIView):
    """Traduce un batch di messaggi."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        messages = request.data.get('messages', [])
        target_lang = request.data.get('target_lang', '')

        if not messages or not target_lang:
            return Response({'error': 'messages and target_lang required'}, status=status.HTTP_400_BAD_REQUEST)

        results = []
        for msg in messages[:50]:  # Max 50 messaggi per batch
            text = msg.get('text', '')
            msg_id = msg.get('id', '')
            if text:
                result = translate_text(
                    text=text,
                    target_lang=target_lang,
                    user_id=request.user.id,
                )
                results.append({
                    'id': msg_id,
                    'original_text': text,
                    'translated_text': result.get('translated_text', text),
                    'source_language': result.get('source_language', ''),
                    'cached': result.get('cached', False),
                })
            else:
                results.append({'id': msg_id, 'original_text': '', 'translated_text': '', 'source_language': '', 'cached': False})

        return Response({'translations': results, 'target_language': target_lang})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def available_languages(request):
    """Lista lingue disponibili per la traduzione."""
    languages = get_installed_languages()
    return Response({'languages': languages})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def check_translation_available(request):
    """Controlla se la traduzione è disponibile per una coppia di lingue."""
    source = request.GET.get('source', '')
    target = request.GET.get('target', '')
    if not target:
        return Response({'error': 'target required'}, status=status.HTTP_400_BAD_REQUEST)
    available = can_translate(source or 'en', target)
    return Response({'available': available, 'source': source, 'target': target})
