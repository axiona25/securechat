"""
Translation engine using Argos Translate (100% offline, open source).
Handles translation, language detection, caching, and language pack management.
"""
import hashlib
import logging
import threading
from typing import Optional

from django.core.cache import cache as redis_cache
from django.conf import settings
from django.db.models import F

logger = logging.getLogger(__name__)

# Redis cache TTL for translations (24 hours)
REDIS_CACHE_TTL = getattr(settings, 'TRANSLATION_CACHE_TTL', 60 * 60 * 24)

# Max text length per translation request
MAX_TEXT_LENGTH = getattr(settings, 'TRANSLATION_MAX_TEXT_LENGTH', 5000)

# Thread lock for argos translate operations (it's not fully thread-safe)
_argos_lock = threading.Lock()


def _generate_cache_key(text: str, source_lang: str, target_lang: str) -> str:
    """Generate a deterministic cache key for a translation."""
    raw = f'{source_lang}:{target_lang}:{text}'
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def detect_language(text: str) -> Optional[str]:
    """
    Detect the language of the given text using langdetect.
    Returns ISO 639-1 code or None if detection fails.
    """
    if not text or not text.strip():
        return None
    try:
        from langdetect import detect
        lang = detect(text)
        # langdetect can return codes like 'zh-cn', 'zh-tw' — normalize
        if '-' in lang:
            lang = lang.split('-')[0]
        return lang
    except Exception as e:
        logger.debug(f'Language detection failed: {e}')
        return None


def get_installed_languages() -> list:
    """
    Return list of installed Argos Translate languages.
    Each dict: {'code': 'en', 'name': 'English'}
    """
    try:
        import argostranslate.translate
        languages = argostranslate.translate.get_installed_languages()
        return [
            {'code': lang.code, 'name': lang.name}
            for lang in languages
        ]
    except Exception as e:
        logger.error(f'Error getting installed languages: {e}')
        return []


def get_installed_pairs() -> list:
    """
    Return list of installed translation pairs.
    Each dict: {'source': 'en', 'source_name': 'English', 'target': 'it', 'target_name': 'Italian'}
    """
    try:
        import argostranslate.translate
        languages = argostranslate.translate.get_installed_languages()
        pairs = []
        for source_lang in languages:
            for target_lang in source_lang.translations_to:
                pairs.append({
                    'source': source_lang.code,
                    'source_name': source_lang.name,
                    'target': target_lang.code,
                    'target_name': target_lang.name,
                })
        return pairs
    except Exception as e:
        logger.error(f'Error getting installed pairs: {e}')
        return []


def is_pair_installed(source_lang: str, target_lang: str) -> bool:
    """Check if a direct translation pair is installed."""
    pairs = get_installed_pairs()
    for p in pairs:
        if p['source'] == source_lang and p['target'] == target_lang:
            return True
    return False


def can_translate(source_lang: str, target_lang: str) -> bool:
    """
    Check if translation is possible, including via pivot through English.
    """
    if source_lang == target_lang:
        return True
    if is_pair_installed(source_lang, target_lang):
        return True
    # Check pivot: source→en + en→target
    if source_lang != 'en' and target_lang != 'en':
        return is_pair_installed(source_lang, 'en') and is_pair_installed('en', target_lang)
    return False


def translate_text(
    text: str,
    target_lang: str,
    source_lang: Optional[str] = None,
    user_id: Optional[int] = None,
) -> dict:
    """
    Translate text to target language using Argos Translate.

    Checks: Redis cache → DB cache → Argos engine.
    Supports pivot translation through English if direct pair not available.

    Args:
        text: text to translate
        target_lang: ISO 639-1 target language code
        source_lang: ISO 639-1 source language code (None = auto-detect)
        user_id: for usage logging

    Returns:
        dict with keys: translated_text, source_language, target_language,
                        detected_language, cached, char_count
    """
    if not text or not text.strip():
        return {
            'translated_text': text or '',
            'source_language': source_lang or '',
            'target_language': target_lang,
            'detected_language': '',
            'cached': False,
            'char_count': 0,
        }

    # Enforce max length
    if len(text) > MAX_TEXT_LENGTH:
        text = text[:MAX_TEXT_LENGTH]

    # Auto-detect source language if not provided
    detected = None
    if not source_lang:
        detected = detect_language(text)
        source_lang = detected or 'en'

    # Same language — return as-is
    if source_lang == target_lang:
        return {
            'translated_text': text,
            'source_language': source_lang,
            'target_language': target_lang,
            'detected_language': detected or source_lang,
            'cached': False,
            'char_count': 0,
        }

    cache_key = _generate_cache_key(text, source_lang, target_lang)

    # 1. Check Redis cache
    redis_result = redis_cache.get(f'trans:{cache_key}')
    if redis_result is not None:
        _log_usage(user_id, source_lang, target_lang, len(text), cached=True)
        return {
            'translated_text': redis_result,
            'source_language': source_lang,
            'target_language': target_lang,
            'detected_language': detected or source_lang,
            'cached': True,
            'char_count': len(text),
        }

    # 2. Check DB cache
    from .models import TranslationCache
    db_entry = TranslationCache.objects.filter(cache_key=cache_key).first()
    if db_entry:
        # Repopulate Redis cache
        redis_cache.set(f'trans:{cache_key}', db_entry.translated_text, REDIS_CACHE_TTL)
        # Increment hit count
        TranslationCache.objects.filter(id=db_entry.id).update(
            hit_count=F('hit_count') + 1
        )
        _log_usage(user_id, source_lang, target_lang, len(text), cached=True)
        return {
            'translated_text': db_entry.translated_text,
            'source_language': source_lang,
            'target_language': target_lang,
            'detected_language': db_entry.detected_language or source_lang,
            'cached': True,
            'char_count': len(text),
        }

    # 3. Translate via Argos
    translated = _argos_translate(text, source_lang, target_lang)

    if translated is None:
        logger.warning(f'Translation failed for {source_lang}→{target_lang}')
        return {
            'translated_text': text,
            'source_language': source_lang,
            'target_language': target_lang,
            'detected_language': detected or source_lang,
            'cached': False,
            'char_count': 0,
            'error': 'Translation pair not available. Install the required language pack.',
        }

    # Save to Redis cache
    redis_cache.set(f'trans:{cache_key}', translated, REDIS_CACHE_TTL)

    # Save to DB cache
    try:
        TranslationCache.objects.update_or_create(
            cache_key=cache_key,
            defaults={
                'source_text': text,
                'translated_text': translated,
                'source_language': source_lang,
                'target_language': target_lang,
                'detected_language': detected or '',
                'char_count': len(text),
            }
        )
    except Exception as e:
        logger.error(f'Error saving translation to DB cache: {e}')

    _log_usage(user_id, source_lang, target_lang, len(text), cached=False)

    return {
        'translated_text': translated,
        'source_language': source_lang,
        'target_language': target_lang,
        'detected_language': detected or source_lang,
        'cached': False,
        'char_count': len(text),
    }


def _argos_translate(text: str, source_lang: str, target_lang: str) -> Optional[str]:
    """
    Perform actual translation using Argos Translate.
    Supports pivot translation through English if direct pair not available.
    Thread-safe via lock.
    """
    import argostranslate.translate

    with _argos_lock:
        try:
            installed_languages = argostranslate.translate.get_installed_languages()

            source_obj = None
            target_obj = None
            for lang in installed_languages:
                if lang.code == source_lang:
                    source_obj = lang
                if lang.code == target_lang:
                    target_obj = lang

            if not source_obj or not target_obj:
                # Try pivot through English
                return _argos_pivot_translate(text, source_lang, target_lang, installed_languages)

            # Try direct translation
            translation_obj = source_obj.get_translation(target_obj)
            if translation_obj:
                return translation_obj.translate(text)

            # No direct pair — try pivot through English
            return _argos_pivot_translate(text, source_lang, target_lang, installed_languages)

        except Exception as e:
            logger.error(f'Argos translation error ({source_lang}→{target_lang}): {e}')
            return None


def _argos_pivot_translate(text: str, source_lang: str, target_lang: str, installed_languages) -> Optional[str]:
    """
    Translate via English pivot: source→en then en→target.
    """
    if source_lang == 'en' or target_lang == 'en':
        return None  # Cannot pivot if one side is already English

    source_obj = None
    english_obj = None
    target_obj = None

    for lang in installed_languages:
        if lang.code == source_lang:
            source_obj = lang
        if lang.code == 'en':
            english_obj = lang
        if lang.code == target_lang:
            target_obj = lang

    if not source_obj or not english_obj or not target_obj:
        return None

    # Step 1: source → en
    to_english = source_obj.get_translation(english_obj)
    if not to_english:
        return None
    english_text = to_english.translate(text)

    # Step 2: en → target
    from_english = english_obj.get_translation(target_obj)
    if not from_english:
        return None
    return from_english.translate(english_text)


def _log_usage(user_id, source_lang, target_lang, char_count, cached):
    """Log translation usage asynchronously."""
    if not user_id:
        return
    try:
        from .models import TranslationUsageLog
        TranslationUsageLog.objects.create(
            user_id=user_id,
            source_language=source_lang,
            target_language=target_lang,
            char_count=char_count,
            cached=cached,
        )
    except Exception as e:
        logger.debug(f'Failed to log translation usage: {e}')


def get_available_packages() -> list:
    """
    List all downloadable Argos Translate language packages.
    Returns list of dicts with source, target, code, etc.
    """
    try:
        import argostranslate.package
        argostranslate.package.update_package_index()
        available = argostranslate.package.get_available_packages()
        return [
            {
                'from_code': pkg.from_code,
                'from_name': pkg.from_name,
                'to_code': pkg.to_code,
                'to_name': pkg.to_name,
                'package_version': getattr(pkg, 'package_version', ''),
            }
            for pkg in available
        ]
    except Exception as e:
        logger.error(f'Error fetching available packages: {e}')
        return []


def install_language_pack(from_code: str, to_code: str) -> bool:
    """
    Download and install an Argos Translate language pack.
    Returns True on success, False on failure.
    """
    try:
        import argostranslate.package
        import argostranslate.translate

        argostranslate.package.update_package_index()
        available = argostranslate.package.get_available_packages()

        target_pkg = None
        for pkg in available:
            if pkg.from_code == from_code and pkg.to_code == to_code:
                target_pkg = pkg
                break

        if not target_pkg:
            logger.warning(f'Language pack {from_code}→{to_code} not found in index')
            return False

        download_path = target_pkg.download()
        argostranslate.package.install_from_path(download_path)

        # Record in DB
        from .models import InstalledLanguagePack
        InstalledLanguagePack.objects.update_or_create(
            source_language=from_code,
            target_language=to_code,
            defaults={
                'source_language_name': target_pkg.from_name,
                'target_language_name': target_pkg.to_name,
                'package_version': getattr(target_pkg, 'package_version', ''),
            }
        )

        logger.info(f'Installed language pack: {from_code}→{to_code}')
        return True

    except Exception as e:
        logger.error(f'Error installing language pack {from_code}→{to_code}: {e}')
        return False
