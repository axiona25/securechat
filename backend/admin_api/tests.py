from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status as http_status

User = get_user_model()


class AdminAuthTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='admin', email='admin@test.com', password='AdminPass123!'
        )
        self.staff = User.objects.create_user(
            username='staff', email='staff@test.com', password='StaffPass123!',
            is_staff=True,
        )
        self.normal = User.objects.create_user(
            username='normal', email='normal@test.com', password='NormalPass123!'
        )

    def test_admin_login_success(self):
        resp = self.client.post('/api/admin-panel/auth/login/', {
            'username': 'admin',
            'password': 'AdminPass123!',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn('access', resp.data)
        self.assertIn('refresh', resp.data)

    def test_admin_login_non_staff_denied(self):
        resp = self.client.post('/api/admin-panel/auth/login/', {
            'username': 'normal',
            'password': 'NormalPass123!',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_401_UNAUTHORIZED)

    def test_admin_login_wrong_password(self):
        resp = self.client.post('/api/admin-panel/auth/login/', {
            'username': 'admin',
            'password': 'WrongPass!',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_401_UNAUTHORIZED)

    def test_admin_me(self):
        self.client.force_authenticate(user=self.admin)
        resp = self.client.get('/api/admin-panel/auth/me/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['username'], 'admin')
        self.assertTrue(resp.data['is_superuser'])

    def test_normal_user_denied_me(self):
        self.client.force_authenticate(user=self.normal)
        resp = self.client.get('/api/admin-panel/auth/me/')
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)


class DashboardTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='dashadmin', email='dashadmin@test.com', password='AdminPass123!'
        )
        self.client.force_authenticate(user=self.admin)
        for i in range(5):
            User.objects.create_user(
                username=f'user{i}', email=f'user{i}@test.com', password='TestPass123!'
            )

    def test_dashboard_stats(self):
        resp = self.client.get('/api/admin-panel/dashboard/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['total_users'], 6)
        self.assertIn('total_messages', resp.data)
        self.assertIn('total_channels', resp.data)

    def test_dashboard_charts(self):
        resp = self.client.get('/api/admin-panel/dashboard/charts/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn('registrations', resp.data)
        self.assertIn('messages', resp.data)
        self.assertIn('calls', resp.data)

    def test_dashboard_charts_custom_days(self):
        resp = self.client.get('/api/admin-panel/dashboard/charts/?days=7')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['days'], 7)

    def test_dashboard_threats(self):
        resp = self.client.get('/api/admin-panel/dashboard/threats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_dashboard_denied_for_normal_user(self):
        normal = User.objects.create_user(
            username='dashdenied', email='dashdenied@test.com', password='TestPass123!'
        )
        self.client.force_authenticate(user=normal)
        resp = self.client.get('/api/admin-panel/dashboard/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)


class AdminUserTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='useradmin', email='useradmin@test.com', password='AdminPass123!'
        )
        self.target_user = User.objects.create_user(
            username='target', email='target@test.com', password='TargetPass123!'
        )
        self.client.force_authenticate(user=self.admin)

    def test_user_list(self):
        resp = self.client.get('/api/admin-panel/users/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn('results', resp.data)
        self.assertGreaterEqual(resp.data['count'], 2)

    def test_user_list_search(self):
        resp = self.client.get('/api/admin-panel/users/?search=target')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['count'], 1)

    def test_user_list_filter_active(self):
        resp = self.client.get('/api/admin-panel/users/?is_active=true')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_user_detail(self):
        resp = self.client.get(f'/api/admin-panel/users/{self.target_user.id}/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertEqual(resp.data['username'], 'target')
        self.assertIn('message_count', resp.data)

    def test_user_update(self):
        resp = self.client.patch(f'/api/admin-panel/users/{self.target_user.id}/', {
            'first_name': 'Updated',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_user_action_deactivate(self):
        resp = self.client.post(
            f'/api/admin-panel/users/{self.target_user.id}/action/',
            {'action': 'deactivate'}
        )
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.target_user.refresh_from_db()
        self.assertFalse(self.target_user.is_active)

    def test_user_action_verify(self):
        resp = self.client.post(
            f'/api/admin-panel/users/{self.target_user.id}/action/',
            {'action': 'verify'}
        )
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.target_user.refresh_from_db()
        self.assertTrue(self.target_user.is_verified)

    def test_user_action_make_staff(self):
        resp = self.client.post(
            f'/api/admin-panel/users/{self.target_user.id}/action/',
            {'action': 'make_staff'}
        )
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.target_user.refresh_from_db()
        self.assertTrue(self.target_user.is_staff)

    def test_user_action_force_logout(self):
        resp = self.client.post(
            f'/api/admin-panel/users/{self.target_user.id}/action/',
            {'action': 'force_logout'}
        )
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_cannot_deactivate_self(self):
        resp = self.client.post(
            f'/api/admin-panel/users/{self.admin.id}/action/',
            {'action': 'deactivate'}
        )
        self.assertEqual(resp.status_code, http_status.HTTP_400_BAD_REQUEST)

    def test_staff_cannot_make_superuser(self):
        staff = User.objects.create_user(
            username='staffonly', email='staffonly@test.com', password='StaffPass123!',
            is_staff=True,
        )
        self.client.force_authenticate(user=staff)
        resp = self.client.post(
            f'/api/admin-panel/users/{self.target_user.id}/action/',
            {'action': 'make_superuser'}
        )
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)


class AdminChannelTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='chanadmin', email='chanadmin@test.com', password='AdminPass123!'
        )
        self.client.force_authenticate(user=self.admin)

    def test_channel_list(self):
        resp = self.client.get('/api/admin-panel/channels/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_channel_categories_list(self):
        resp = self.client.get('/api/admin-panel/channel-categories/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)


class AdminSecurityTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='secadmin', email='secadmin@test.com', password='AdminPass123!'
        )
        self.client.force_authenticate(user=self.admin)

    def test_threat_list(self):
        resp = self.client.get('/api/admin-panel/security/threats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_security_stats(self):
        resp = self.client.get('/api/admin-panel/security/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_anomaly_list(self):
        resp = self.client.get('/api/admin-panel/security/anomalies/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)


class AdminNotificationTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='notifadmin', email='notifadmin@test.com', password='AdminPass123!'
        )
        self.client.force_authenticate(user=self.admin)

    def test_notification_stats(self):
        resp = self.client.get('/api/admin-panel/notifications/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)

    def test_broadcast_denied_for_staff(self):
        staff = User.objects.create_user(
            username='staffnotif', email='staffnotif@test.com', password='StaffPass123!',
            is_staff=True,
        )
        self.client.force_authenticate(user=staff)
        resp = self.client.post('/api/admin-panel/notifications/broadcast/', {
            'title': 'Test',
            'body': 'Test broadcast',
            'target': 'all',
        })
        self.assertEqual(resp.status_code, http_status.HTTP_403_FORBIDDEN)


class AdminSystemTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='sysadmin', email='sysadmin@test.com', password='AdminPass123!'
        )
        self.client.force_authenticate(user=self.admin)

    def test_system_info(self):
        resp = self.client.get('/api/admin-panel/system/info/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn('django_version', resp.data)
        self.assertIn('python_version', resp.data)
        self.assertIn('redis', resp.data)
        self.assertIn('firebase_enabled', resp.data)


class AdminTranslationTests(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.admin = User.objects.create_superuser(
            username='transadmin', email='transadmin@test.com', password='AdminPass123!'
        )
        self.client.force_authenticate(user=self.admin)

    def test_translation_stats(self):
        resp = self.client.get('/api/admin-panel/translations/stats/')
        self.assertEqual(resp.status_code, http_status.HTTP_200_OK)
        self.assertIn('total_translations', resp.data)
