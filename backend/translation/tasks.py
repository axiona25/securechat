import logging
from celery import shared_task
from django.utils import timezone
from datetime import timedelta

logger = logging.getLogger(__name__)


def _get_message_text(message):
    """Get translatable text from a chat Message (content_for_translation)."""
    return getattr(message, 'content_for_translation', '') or ''


@shared_task(name='translation.install_language_pack')
def install_language_pack_task(from_code, to_code):
    """
    Celery task to download and install an Argos Translate language pack.
    This can take several minutes depending on the package size and network.
    """
    from .engine import install_language_pack

    logger.info(f'Starting language pack installation: {from_code}→{to_code}')
    success = install_language_pack(from_code, to_code)

    if success:
        logger.info(f'Successfully installed language pack: {from_code}→{to_code}')
    else:
        logger.error(f'Failed to install language pack: {from_code}→{to_code}')

    return {'from_code': from_code, 'to_code': to_code, 'success': success}


@shared_task(name='translation.install_default_packs')
def install_default_packs():
    """
    Install a set of default language packs for common languages.
    Run once during initial setup.
    """
    from .engine import install_language_pack

    default_pairs = [
        ('en', 'it'), ('it', 'en'),
        ('en', 'es'), ('es', 'en'),
        ('en', 'fr'), ('fr', 'en'),
        ('en', 'de'), ('de', 'en'),
        ('en', 'pt'), ('pt', 'en'),
        ('en', 'ru'), ('ru', 'en'),
        ('en', 'zh'), ('zh', 'en'),
        ('en', 'ar'), ('ar', 'en'),
        ('en', 'ja'), ('ja', 'en'),
        ('en', 'ko'), ('ko', 'en'),
    ]

    results = []
    for from_code, to_code in default_pairs:
        success = install_language_pack(from_code, to_code)
        results.append({
            'pair': f'{from_code}→{to_code}',
            'success': success,
        })
        logger.info(f'Pack {from_code}→{to_code}: {"OK" if success else "FAILED"}')

    return results


@shared_task(name='translation.translate_message_async')
def translate_message_async(message_id, user_id, target_lang):
    """
    Celery task to translate a message asynchronously.
    Used for auto-translate feature — translates in background
    and result is cached for when client requests it.
    """
    from chat.models import Message
    from .engine import translate_text

    try:
        message = Message.objects.get(id=message_id)
    except Message.DoesNotExist:
        logger.warning(f'Message {message_id} not found for async translation')
        return None

    text = _get_message_text(message)
    if not text or not text.strip():
        return None

    result = translate_text(
        text=text,
        target_lang=target_lang,
        source_lang=None,
        user_id=user_id,
    )

    logger.debug(
        f'Async translation for msg {message_id}: '
        f'{result.get("source_language")}→{result.get("target_language")} '
        f'(cached={result.get("cached")})'
    )

    return result


@shared_task(name='translation.cleanup_old_cache')
def cleanup_old_cache(days=30):
    """
    Remove cache entries older than N days with 0 hits.
    Keep popular translations indefinitely.
    Run weekly via Celery Beat.
    """
    from .models import TranslationCache

    cutoff = timezone.now() - timedelta(days=days)
    deleted, _ = TranslationCache.objects.filter(
        created_at__lt=cutoff,
        hit_count=0,
    ).delete()
    if deleted:
        logger.info(f'Cleaned up {deleted} unused translation cache entries')
    return deleted


@shared_task(name='translation.cleanup_old_usage_logs')
def cleanup_old_usage_logs(days=90):
    """
    Remove usage logs older than N days.
    Run monthly via Celery Beat.
    """
    from .models import TranslationUsageLog

    cutoff = timezone.now() - timedelta(days=days)
    deleted, _ = TranslationUsageLog.objects.filter(
        created_at__lt=cutoff,
    ).delete()
    if deleted:
        logger.info(f'Cleaned up {deleted} old translation usage logs')
    return deleted
