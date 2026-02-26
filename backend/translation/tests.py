import uuid
from unittest.mock import patch, MagicMock
from django.test import TestCase, override_settings
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status as http_status

from .models import (
    TranslationPreference, ConversationTranslationSetting,
    TranslationCache, InstalledLanguagePack, TranslationUsageLog,
)
from . import engine

User = get_user_model()


class TranslationPreferenceTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='transuser', email='trans@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    def test_get_preferences_auto_created(self):
        resp = self.client.get('/api/translation/preferences/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['preferred_language'], 'en')
        self.assertFalse(resp.data['auto_translate'])

    def test_update_preferences(self):
        resp = self.client.patch('/api/translation/preferences/', {
            'preferred_language': 'it',
            'auto_translate': True,
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['preferred_language'], 'it')
        self.assertTrue(resp.data['auto_translate'])

    def test_conversation_translation_setting(self):
        conv_id = str(uuid.uuid4())
        resp = self.client.post('/api/translation/conversations/', {
            'conversation_id': conv_id,
            'auto_translate': True,
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertTrue(
            ConversationTranslationSetting.objects.filter(
                user=self.user, conversation_id=conv_id
            ).exists()
        )

    def test_delete_conversation_setting(self):
        conv_id = uuid.uuid4()
        ConversationTranslationSetting.objects.create(
            user=self.user, conversation_id=conv_id, auto_translate=True
        )
        resp = self.client.delete(f'/api/translation/conversations/{conv_id}/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)


class LanguageDetectionTests(TestCase):

    def test_detect_italian(self):
        result = engine.detect_language('Ciao, come stai? Oggi è una bella giornata.')
        self.assertEqual(result, 'it')

    def test_detect_english(self):
        result = engine.detect_language('Hello, how are you? Today is a beautiful day.')
        self.assertEqual(result, 'en')

    def test_detect_spanish(self):
        result = engine.detect_language('Hola, ¿cómo estás? Hoy es un día hermoso.')
        self.assertEqual(result, 'es')

    def test_detect_empty(self):
        result = engine.detect_language('')
        self.assertIsNone(result)

    def test_detect_none(self):
        result = engine.detect_language(None)
        self.assertIsNone(result)


class DetectLanguageAPITests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='detectuser', email='detect@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    def test_detect_api(self):
        resp = self.client.post('/api/translation/detect/', {
            'text': 'Bonjour, comment allez-vous?',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['detected_language'], 'fr')

    def test_detect_api_empty(self):
        resp = self.client.post('/api/translation/detect/', {'text': ''})
        self.assertEqual(resp.status_code, http_status.HTTP_400_BAD_REQUEST)


class TranslationCacheTests(TestCase):

    def test_generate_cache_key_deterministic(self):
        key1 = engine._generate_cache_key('hello', 'en', 'it')
        key2 = engine._generate_cache_key('hello', 'en', 'it')
        self.assertEqual(key1, key2)

    def test_generate_cache_key_different_for_different_input(self):
        key1 = engine._generate_cache_key('hello', 'en', 'it')
        key2 = engine._generate_cache_key('hello', 'en', 'fr')
        self.assertNotEqual(key1, key2)

    def test_cache_key_different_for_different_text(self):
        key1 = engine._generate_cache_key('hello', 'en', 'it')
        key2 = engine._generate_cache_key('world', 'en', 'it')
        self.assertNotEqual(key1, key2)


class TranslateTextAPITests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='translateuser', email='translate@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    @patch('translation.engine._argos_translate')
    def test_translate_text(self, mock_argos):
        mock_argos.return_value = 'Ciao mondo'

        resp = self.client.post('/api/translation/translate/text/', {
            'text': 'Hello world',
            'target_language': 'it',
            'source_language': 'en',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['translated_text'], 'Ciao mondo')
        self.assertEqual(resp.data['source_language'], 'en')
        self.assertEqual(resp.data['target_language'], 'it')
        self.assertFalse(resp.data['cached'])

    @patch('translation.engine._argos_translate')
    def test_translate_text_uses_cache(self, mock_argos):
        mock_argos.return_value = 'Ciao mondo'

        self.client.post('/api/translation/translate/text/', {
            'text': 'Hello world',
            'target_language': 'it',
            'source_language': 'en',
        })

        resp = self.client.post('/api/translation/translate/text/', {
            'text': 'Hello world',
            'target_language': 'it',
            'source_language': 'en',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['translated_text'], 'Ciao mondo')
        self.assertTrue(resp.data['cached'])
        self.assertEqual(mock_argos.call_count, 1)

    def test_translate_same_language_no_op(self):
        resp = self.client.post('/api/translation/translate/text/', {
            'text': 'Hello world',
            'target_language': 'en',
            'source_language': 'en',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['translated_text'], 'Hello world')
        self.assertEqual(resp.data['char_count'], 0)

    def test_translate_empty_text(self):
        resp = self.client.post('/api/translation/translate/text/', {
            'text': '',
            'target_language': 'it',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_400_BAD_REQUEST)

    @patch('translation.engine._argos_translate')
    def test_translate_auto_detect(self, mock_argos):
        mock_argos.return_value = 'Hello world'

        resp = self.client.post('/api/translation/translate/text/', {
            'text': 'Ciao mondo',
            'target_language': 'en',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn(resp.data['detected_language'], ['it', 'en'])


class TranslateMessageAPITests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='msguser', email='msg@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    @patch('translation.engine._argos_translate')
    def test_translate_message(self, mock_argos):
        mock_argos.return_value = 'Ciao mondo'

        from chat.models import Conversation, ConversationParticipant, Message

        conv = Conversation.objects.create()
        ConversationParticipant.objects.create(
            conversation=conv, user=self.user
        )
        msg = Message.objects.create(
            conversation=conv,
            sender=self.user,
            content_for_translation='Hello world',
        )

        resp = self.client.post('/api/translation/translate/message/', {
            'message_id': str(msg.id),
            'target_language': 'it',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['translated_text'], 'Ciao mondo')


class LanguagePackTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='admin', email='admin@test.com', password='AdminPass123!'
        )
        self.user = User.objects.create_user(
            username='normaluser', email='normal@test.com', password='TestPass123!'
        )

    def test_installed_packages_list(self):
        InstalledLanguagePack.objects.create(
            source_language='en', source_language_name='English',
            target_language='it', target_language_name='Italian',
        )
        self.client.force_authenticate(user=self.user)
        resp = self.client.get('/api/translation/packages/installed/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(len(resp.data), 1)

    @patch('translation.tasks.install_language_pack_task.delay')
    def test_install_package_admin_only(self, mock_task):
        self.client.force_authenticate(user=self.admin)
        resp = self.client.post('/api/translation/packages/install/', {
            'from_code': 'en',
            'to_code': 'it',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_202_ACCEPTED)
        mock_task.assert_called_once_with('en', 'it')

    def test_install_package_denied_for_normal_user(self):
        self.client.force_authenticate(user=self.user)
        resp = self.client.post('/api/translation/packages/install/', {
            'from_code': 'en',
            'to_code': 'it',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)

    def test_available_packages_admin_only(self):
        self.client.force_authenticate(user=self.user)
        resp = self.client.get('/api/translation/packages/available/')
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)


class TranslationStatsTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='statuser', email='stat@test.com', password='TestPass123!'
        )
        self.admin = User.objects.create_superuser(
            username='statadmin', email='statadmin@test.com', password='AdminPass123!'
        )

    def test_my_stats(self):
        TranslationUsageLog.objects.create(
            user=self.user, source_language='en', target_language='it',
            char_count=100, cached=False
        )
        TranslationUsageLog.objects.create(
            user=self.user, source_language='en', target_language='it',
            char_count=50, cached=True
        )
        self.client.force_authenticate(user=self.user)
        resp = self.client.get('/api/translation/stats/me/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['total_translations'], 2)
        self.assertEqual(resp.data['total_chars'], 150)
        self.assertEqual(resp.data['cached_translations'], 1)

    def test_admin_stats(self):
        self.client.force_authenticate(user=self.admin)
        resp = self.client.get('/api/translation/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn('total_translations', resp.data)
        self.assertIn('cache_hit_rate', resp.data)

    def test_admin_stats_denied_for_normal_user(self):
        self.client.force_authenticate(user=self.user)
        resp = self.client.get('/api/translation/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)


class LanguageInfoAPITests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='languser', email='lang@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    @patch('translation.engine.get_installed_languages')
    def test_installed_languages(self, mock_langs):
        mock_langs.return_value = [
            {'code': 'en', 'name': 'English'},
            {'code': 'it', 'name': 'Italian'},
        ]
        resp = self.client.get('/api/translation/languages/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['count'], 2)

    @patch('translation.engine.get_installed_pairs')
    def test_installed_pairs(self, mock_pairs):
        mock_pairs.return_value = [
            {'source': 'en', 'source_name': 'English', 'target': 'it', 'target_name': 'Italian'},
        ]
        resp = self.client.get('/api/translation/languages/pairs/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['count'], 1)

    @patch('translation.engine.can_translate')
    @patch('translation.engine.is_pair_installed')
    def test_check_pair(self, mock_direct, mock_can):
        mock_can.return_value = True
        mock_direct.return_value = True
        resp = self.client.get('/api/translation/languages/check/?source=en&target=it')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertTrue(resp.data['available'])
        self.assertTrue(resp.data['direct'])
        self.assertFalse(resp.data['pivot'])

    def test_check_pair_missing_params(self):
        self.client.force_authenticate(user=self.user)
        resp = self.client.get('/api/translation/languages/check/')
        self.assertEqual(resp.status_code, http_status.HTTP_400_BAD_REQUEST)
