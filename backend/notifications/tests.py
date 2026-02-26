import uuid
from unittest.mock import patch, MagicMock
from django.test import TestCase, override_settings
from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework import status as http_status
from datetime import time, timedelta

from .models import (
    DeviceToken, NotificationPreference, MuteRule,
    Notification, NotificationType,
)
from .services import NotificationService

User = get_user_model()


def _results(resp):
    """Get list from paginated or non-paginated response."""
    if isinstance(resp.data, dict) and 'results' in resp.data:
        return resp.data['results']
    return resp.data if isinstance(resp.data, list) else []


class DeviceTokenTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='testuser', email='test@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    def test_register_device(self):
        resp = self.client.post('/api/notifications/devices/register/', {
            'token': 'fcm_token_abc123',
            'platform': 'android',
            'device_id': 'device-001',
            'device_name': 'Pixel 7',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_201_CREATED)
        self.assertTrue(DeviceToken.objects.filter(user=self.user, device_id='device-001').exists())

    def test_register_device_upsert(self):
        DeviceToken.objects.create(
            user=self.user, token='old_token', platform='android', device_id='device-002'
        )
        resp = self.client.post('/api/notifications/devices/register/', {
            'token': 'new_token',
            'platform': 'android',
            'device_id': 'device-002',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_201_CREATED)
        token = DeviceToken.objects.get(user=self.user, device_id='device-002')
        self.assertEqual(token.token, 'new_token')

    def test_unregister_device(self):
        DeviceToken.objects.create(
            user=self.user, token='tok', platform='ios', device_id='device-003'
        )
        resp = self.client.post('/api/notifications/devices/unregister/', {
            'device_id': 'device-003',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertFalse(DeviceToken.objects.filter(device_id='device-003').exists())

    def test_list_devices(self):
        DeviceToken.objects.create(
            user=self.user, token='t1', platform='android', device_id='d1'
        )
        DeviceToken.objects.create(
            user=self.user, token='t2', platform='ios', device_id='d2'
        )
        resp = self.client.get('/api/notifications/devices/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(len(resp.data), 2)


class NotificationPreferenceTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='prefuser', email='pref@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    def test_get_preferences_auto_created(self):
        resp = self.client.get('/api/notifications/preferences/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertTrue(resp.data['new_message'])

    def test_update_preferences(self):
        resp = self.client.patch('/api/notifications/preferences/', {
            'new_message': False,
            'dnd_enabled': True,
            'dnd_start_time': '22:00:00',
            'dnd_end_time': '07:00:00',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertFalse(resp.data['new_message'])
        self.assertTrue(resp.data['dnd_enabled'])


class MuteRuleTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='muteuser', email='mute@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    def test_create_mute_rule(self):
        resp = self.client.post('/api/notifications/mute/', {
            'target_type': 'conversation',
            'target_id': str(uuid.uuid4()),
        })
        self.assertEqual(resp.status_code, http_status.HTTP_201_CREATED)
        self.assertTrue(resp.data['is_active'])

    def test_create_mute_rule_with_expiry(self):
        future = (timezone.now() + timedelta(hours=2)).isoformat()
        resp = self.client.post('/api/notifications/mute/', {
            'target_type': 'group',
            'target_id': str(uuid.uuid4()),
            'muted_until': future,
        })
        self.assertEqual(resp.status_code, http_status.HTTP_201_CREATED)
        self.assertTrue(resp.data['is_active'])

    def test_delete_mute_rule(self):
        target_id = str(uuid.uuid4())
        MuteRule.objects.create(
            user=self.user, target_type='channel', target_id=target_id
        )
        resp = self.client.delete(f'/api/notifications/mute/channel/{target_id}/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_list_mute_rules(self):
        MuteRule.objects.create(
            user=self.user, target_type='conversation', target_id=str(uuid.uuid4())
        )
        resp = self.client.get('/api/notifications/mute/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(len(resp.data), 1)


class NotificationHistoryTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='notifuser', email='notif@test.com', password='TestPass123!'
        )
        self.sender = User.objects.create_user(
            username='sender1', email='sender@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=self.user)

    def _create_notification(self, **kwargs):
        defaults = {
            'recipient': self.user,
            'sender': self.sender,
            'notification_type': NotificationType.NEW_MESSAGE,
            'title': 'Test',
            'body': 'Test body',
        }
        defaults.update(kwargs)
        return Notification.objects.create(**defaults)

    def test_list_notifications(self):
        self._create_notification()
        self._create_notification(notification_type=NotificationType.MISSED_CALL, title='Missed')
        resp = self.client.get('/api/notifications/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(len(_results(resp)), 2)

    def test_filter_by_type(self):
        self._create_notification()
        self._create_notification(notification_type=NotificationType.MISSED_CALL, title='Missed')
        resp = self.client.get('/api/notifications/?type=missed_call')
        self.assertEqual(len(_results(resp)), 1)

    def test_filter_unread(self):
        self._create_notification()
        n2 = self._create_notification(title='Read')
        n2.mark_as_read()
        resp = self.client.get('/api/notifications/?unread=true')
        self.assertEqual(len(_results(resp)), 1)

    def test_mark_read(self):
        n = self._create_notification()
        resp = self.client.post(f'/api/notifications/{n.id}/read/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        n.refresh_from_db()
        self.assertTrue(n.is_read)
        self.assertIsNotNone(n.read_at)

    def test_mark_all_read(self):
        self._create_notification()
        self._create_notification()
        resp = self.client.post('/api/notifications/read-all/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(Notification.objects.filter(recipient=self.user, is_read=False).count(), 0)

    def test_delete_notification(self):
        n = self._create_notification()
        resp = self.client.delete(f'/api/notifications/{n.id}/delete/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertFalse(Notification.objects.filter(id=n.id).exists())

    def test_clear_read_notifications(self):
        n1 = self._create_notification()
        n1.mark_as_read()
        self._create_notification()  # unread
        resp = self.client.delete('/api/notifications/clear/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(Notification.objects.filter(recipient=self.user).count(), 1)

    def test_badge_count(self):
        self._create_notification()
        self._create_notification(notification_type=NotificationType.MISSED_CALL, title='MC')
        n3 = self._create_notification()
        n3.mark_as_read()
        resp = self.client.get('/api/notifications/badge/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['unread_count'], 2)


class NotificationServiceTests(TestCase):

    def setUp(self):
        self.user = User.objects.create_user(
            username='svcuser', email='svc@test.com', password='TestPass123!'
        )
        self.sender = User.objects.create_user(
            username='svcsender', email='svcsender@test.com', password='TestPass123!'
        )

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_creates_notification(self, mock_task):
        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Hello',
            body='World',
            sender_id=self.sender.id,
        )
        self.assertIsNotNone(n)
        self.assertEqual(n.recipient_id, self.user.id)
        self.assertTrue(mock_task.called)

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_skips_self_notification(self, mock_task):
        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Self',
            body='Self',
            sender_id=self.user.id,
        )
        self.assertIsNone(n)
        self.assertFalse(mock_task.called)

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_respects_preference_disabled(self, mock_task):
        prefs, _ = NotificationPreference.objects.get_or_create(user=self.user)
        prefs.new_message = False
        prefs.save()

        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Disabled',
            body='Should not send',
            sender_id=self.sender.id,
        )
        self.assertIsNone(n)

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_respects_dnd(self, mock_task):
        prefs, _ = NotificationPreference.objects.get_or_create(user=self.user)
        prefs.dnd_enabled = True
        prefs.save()

        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.NEW_MESSAGE,
            title='DND',
            body='Should not send during DND',
            sender_id=self.sender.id,
        )
        self.assertIsNone(n)

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_high_priority_bypasses_dnd(self, mock_task):
        prefs, _ = NotificationPreference.objects.get_or_create(user=self.user)
        prefs.dnd_enabled = True
        prefs.save()

        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.INCOMING_CALL,
            title='Call',
            body='Incoming call',
            sender_id=self.sender.id,
            high_priority=True,
        )
        self.assertIsNotNone(n)
        self.assertTrue(mock_task.called)

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_respects_mute_rule(self, mock_task):
        conv_id = str(uuid.uuid4())
        MuteRule.objects.create(
            user=self.user, target_type='conversation', target_id=conv_id
        )

        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Muted',
            body='Should not send',
            sender_id=self.sender.id,
            target_type='conversation',
            target_id=conv_id,
        )
        self.assertIsNone(n)

    @patch('notifications.tasks.deliver_push_notification.delay')
    def test_send_expired_mute_allows_notification(self, mock_task):
        conv_id = str(uuid.uuid4())
        MuteRule.objects.create(
            user=self.user,
            target_type='conversation',
            target_id=conv_id,
            muted_until=timezone.now() - timedelta(hours=1),  # expired
        )

        n = NotificationService.send(
            recipient_id=self.user.id,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Unmuted',
            body='Should send',
            sender_id=self.sender.id,
            target_type='conversation',
            target_id=conv_id,
        )
        self.assertIsNotNone(n)

    def test_dnd_time_range_normal(self):
        prefs, _ = NotificationPreference.objects.get_or_create(user=self.user)
        prefs.dnd_enabled = True
        prefs.dnd_start_time = time(22, 0)
        prefs.dnd_end_time = time(7, 0)
        prefs.save()

        # 23:00 should be in DND
        self.assertTrue(prefs.is_in_dnd(current_time=time(23, 0)))
        # 03:00 should be in DND
        self.assertTrue(prefs.is_in_dnd(current_time=time(3, 0)))
        # 12:00 should NOT be in DND
        self.assertFalse(prefs.is_in_dnd(current_time=time(12, 0)))

    def test_badge_count(self):
        Notification.objects.create(
            recipient=self.user, notification_type=NotificationType.NEW_MESSAGE,
            title='M1', body='b1'
        )
        Notification.objects.create(
            recipient=self.user, notification_type=NotificationType.MISSED_CALL,
            title='MC1', body='b2'
        )
        n3 = Notification.objects.create(
            recipient=self.user, notification_type=NotificationType.NEW_MESSAGE,
            title='M2', body='b3'
        )
        n3.mark_as_read()

        badge = NotificationService.get_badge_count(self.user.id)
        self.assertEqual(badge['unread_count'], 2)
        self.assertEqual(badge['by_type'].get('new_message', 0), 1)
        self.assertEqual(badge['by_type'].get('missed_call', 0), 1)


class FCMTests(TestCase):

    def setUp(self):
        self.user = User.objects.create_user(
            username='fcmuser', email='fcm@test.com', password='TestPass123!'
        )

    @patch('notifications.fcm.messaging')
    @override_settings(FIREBASE_ENABLED=True)
    def test_send_push_success(self, mock_messaging):
        DeviceToken.objects.create(
            user=self.user, token='valid_token', platform='android', device_id='d1'
        )
        notification = Notification.objects.create(
            recipient=self.user,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Test Push',
            body='Hello',
            data={'sound_enabled': True},
        )

        mock_response = MagicMock()
        mock_response.success_count = 1
        mock_response.failure_count = 0
        mock_send_resp = MagicMock()
        mock_send_resp.exception = None
        mock_send_resp.message_id = 'msg_123'
        mock_response.responses = [mock_send_resp]
        mock_messaging.send_each_for_multicast.return_value = mock_response

        from .fcm import send_push_notification
        success, failure = send_push_notification(notification)
        self.assertEqual(success, 1)
        self.assertEqual(failure, 0)
        notification.refresh_from_db()
        self.assertTrue(notification.fcm_sent)

    @patch('notifications.fcm.messaging')
    @override_settings(FIREBASE_ENABLED=True)
    def test_invalid_token_deactivated(self, mock_messaging):
        DeviceToken.objects.create(
            user=self.user, token='invalid_token', platform='android', device_id='d2'
        )
        notification = Notification.objects.create(
            recipient=self.user,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Test',
            body='Hello',
            data={},
        )

        mock_response = MagicMock()
        mock_response.success_count = 0
        mock_response.failure_count = 1
        mock_exception = MagicMock()
        mock_exception.code = 'UNREGISTERED'
        mock_send_resp = MagicMock()
        mock_send_resp.exception = mock_exception
        mock_send_resp.message_id = None
        mock_response.responses = [mock_send_resp]
        mock_messaging.send_each_for_multicast.return_value = mock_response

        from .fcm import send_push_notification
        success, failure = send_push_notification(notification)
        self.assertEqual(success, 0)
        self.assertEqual(failure, 1)

        token = DeviceToken.objects.get(device_id='d2')
        self.assertFalse(token.is_active)

    @override_settings(FIREBASE_ENABLED=False)
    def test_firebase_disabled_skips(self):
        notification = Notification.objects.create(
            recipient=self.user,
            notification_type=NotificationType.NEW_MESSAGE,
            title='Test',
            body='Hello',
        )
        from .fcm import send_push_notification
        success, failure = send_push_notification(notification)
        self.assertEqual(success, 0)
        self.assertEqual(failure, 0)
