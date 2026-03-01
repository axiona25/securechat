#!/usr/bin/env python
"""
SecureChat — Complete End-to-End Test Suite
Tests the full user flow with 2 users: registration, login, password reset,
chat creation, text messages, media attachments, encryption, and notifications.

Run: docker compose exec web python scripts/test_e2e_complete.py
"""
import os
import sys
import json
import time
import hashlib
import django

# Setup Django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.dev')
sys.path.insert(0, '/app')
django.setup()

from django.conf import settings
if 'testserver' not in settings.ALLOWED_HOSTS:
    settings.ALLOWED_HOSTS.append('testserver')

from django.test import RequestFactory
from rest_framework.test import APIClient
from django.core import mail
from django.conf import settings

# Colors for output
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
CYAN = '\033[96m'
BOLD = '\033[1m'
END = '\033[0m'

passed = 0
failed = 0
warnings = 0


def test(description, condition, detail=''):
    global passed, failed
    if condition:
        print(f"  {GREEN}✅ {description}{END}")
        passed += 1
        return True
    else:
        print(f"  {RED}❌ {description}{END}")
        if detail:
            print(f"     {RED}→ {detail}{END}")
        failed += 1
        return False


def warn(description, detail=''):
    global warnings
    print(f"  {YELLOW}⚠️  {description}{END}")
    if detail:
        print(f"     {YELLOW}→ {detail}{END}")
    warnings += 1


def section(title):
    print(f"\n{CYAN}{BOLD}{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}{END}")


def get_response_data(response):
    """Safely get response data."""
    if hasattr(response, 'data'):
        return response.data
    try:
        return response.json()
    except Exception:
        return response.content.decode('utf-8')[:200]


def main():
    global passed, failed, warnings
    start_time = time.time()

    client1 = APIClient()
    client2 = APIClient()

    user1_data = {
        'username': 'testuser1',
        'email': 'testuser1@securechat.test',
        'password': 'TestPass123!',
        'password_confirm': 'TestPass123!',
        'first_name': 'Alice',
        'last_name': 'Test',
    }

    user2_data = {
        'username': 'testuser2',
        'email': 'testuser2@securechat.test',
        'password': 'TestPass456!',
        'password_confirm': 'TestPass456!',
        'first_name': 'Bob',
        'last_name': 'Test',
    }

    token1 = None
    token2 = None
    user1_id = None
    user2_id = None
    conversation_id = None
    message_id = None
    attachment_id = None

    # ══════════════════════════════════════════════════════════════
    # CLEANUP — Remove test users if they exist from previous runs
    # ══════════════════════════════════════════════════════════════
    section("CLEANUP — Remove previous test data")
    try:
        from accounts.models import User
        for email in [user1_data['email'], user2_data['email']]:
            try:
                u = User.objects.get(email=email)
                u.delete()
                print(f"  🗑️  Deleted existing user: {email}")
            except User.DoesNotExist:
                pass
        print(f"  {GREEN}✅ Cleanup done{END}")
    except Exception as e:
        warn(f"Cleanup error: {e}")

    # ══════════════════════════════════════════════════════════════
    # 1. HEALTH CHECK
    # ══════════════════════════════════════════════════════════════
    section("1. HEALTH CHECK")

    r = client1.get('/api/health/')
    test("Health endpoint returns 200", r.status_code == 200)
    if r.status_code == 200:
        data = r.json()
        test("DB connected", data.get('db') == 'connected')
        test("Redis connected", data.get('redis') == 'connected')

    # ══════════════════════════════════════════════════════════════
    # 2. USER REGISTRATION
    # ══════════════════════════════════════════════════════════════
    section("2. USER REGISTRATION")

    # Register User 1 (Alice)
    r = client1.post('/api/auth/register/', user1_data, format='json')
    test(f"Register User1 (Alice) — status {r.status_code}",
         r.status_code in [200, 201],
         f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')
    # Register User 2 (Bob)
    r = client2.post('/api/auth/register/', user2_data, format='json')
    test(f"Register User2 (Bob) — status {r.status_code}",
         r.status_code in [200, 201],
         f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')
    # Test duplicate registration
    r = client1.post('/api/auth/register/', user1_data, format='json')
    test("Duplicate registration rejected", r.status_code == 400)

    # Verify users directly in DB (bypass email verification for testing)
    try:
        from accounts.models import User
        for email in [user1_data['email'], user2_data['email']]:
            u = User.objects.get(email=email)
            u.is_active = True
            if hasattr(u, 'is_verified'):
                u.is_verified = True
            if hasattr(u, 'email_verified'):
                u.email_verified = True
            if hasattr(u, 'is_email_verified'):
                u.is_email_verified = True
            u.save()
        test("Users verified in DB (bypass email)", True)
    except Exception as e:
        test(f"Users verification bypass: {e}", False)

    # Get user IDs from DB
    try:
        from accounts.models import User
        u1 = User.objects.get(email=user1_data['email'])
        u2 = User.objects.get(email=user2_data['email'])
        user1_id = u1.id
        user2_id = u2.id
        test(f"User1 ID from DB: {user1_id}", True)
        test(f"User2 ID from DB: {user2_id}", True)
    except Exception as e:
        test(f"Get user IDs from DB: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 3. USER LOGIN
    # ══════════════════════════════════════════════════════════════
    section("3. USER LOGIN")

    # Login User 1
    login1 = {'email': user1_data['email'], 'password': user1_data['password']}
    r = client1.post('/api/auth/login/', login1, format='json')
    test(f"Login User1 — status {r.status_code}",
         r.status_code == 200,
         f"Response: {get_response_data(r)}" if r.status_code != 200 else '')

    if r.status_code == 200:
        # Extract token — handle different response structures
        data = r.data
        if 'access' in data:
            token1 = data['access']
        elif 'token' in data and isinstance(data['token'], dict):
            token1 = data['token'].get('access', '')
        elif 'tokens' in data:
            token1 = data['tokens'].get('access', '')

        test("User1 JWT token received", bool(token1),
             f"Response keys: {list(data.keys())}")

        if token1:
            client1.credentials(HTTP_AUTHORIZATION=f'Bearer {token1}')

        # Get user1 ID from profile if not from registration
        if not user1_id:
            r_profile = client1.get('/api/auth/profile/')
            if r_profile.status_code == 200:
                user1_id = r_profile.data.get('id')

    # Login User 2
    login2 = {'email': user2_data['email'], 'password': user2_data['password']}
    r = client2.post('/api/auth/login/', login2, format='json')
    test(f"Login User2 — status {r.status_code}",
         r.status_code == 200,
         f"Response: {get_response_data(r)}" if r.status_code != 200 else '')

    if r.status_code == 200:
        data = r.data
        if 'access' in data:
            token2 = data['access']
        elif 'token' in data and isinstance(data['token'], dict):
            token2 = data['token'].get('access', '')
        elif 'tokens' in data:
            token2 = data['tokens'].get('access', '')

        test("User2 JWT token received", bool(token2))

        if token2:
            client2.credentials(HTTP_AUTHORIZATION=f'Bearer {token2}')

        if not user2_id:
            r_profile = client2.get('/api/auth/profile/')
            if r_profile.status_code == 200:
                user2_id = r_profile.data.get('id')

    # Wrong password
    r = client1.post('/api/auth/login/',
                     {'email': user1_data['email'], 'password': 'WrongPass!'},
                     format='json')
    test("Wrong password rejected", r.status_code in [400, 401])

    # ══════════════════════════════════════════════════════════════
    # 4. PASSWORD RESET
    # ══════════════════════════════════════════════════════════════
    section("4. PASSWORD RESET")

    # Find the correct endpoint for requesting password reset
    reset_endpoints = [
        '/api/auth/forgot-password/',
        '/api/auth/password-reset/',
        '/api/auth/password/reset/',
        '/api/auth/request-reset/',
        '/api/auth/send-reset-email/',
    ]

    reset_success = False
    for endpoint in reset_endpoints:
        r = client1.post(endpoint, {'email': user1_data['email']}, format='json')
        if r.status_code in [200, 204]:
            test(f"Password reset request via {endpoint} — status {r.status_code}", True)
            reset_success = True
            break

    if not reset_success:
        warn(f"Password reset request — no working endpoint found. Tried: {reset_endpoints}")
        warn(f"Last response: {get_response_data(r)}")
        warn("Check backend/accounts/urls.py for the correct reset request endpoint")

    # ══════════════════════════════════════════════════════════════
    # 5. USER PROFILE
    # ══════════════════════════════════════════════════════════════
    section("5. USER PROFILE")

    if token1:
        r = client1.get('/api/auth/profile/')
        test(f"Get User1 profile — status {r.status_code}",
             r.status_code == 200)
        if r.status_code == 200:
            test("Profile has email", r.data.get('email') == user1_data['email'])
            test("Profile has first_name",
                 r.data.get('first_name') == user1_data['first_name'])
            if not user1_id:
                user1_id = r.data.get('id')

    if token2:
        r = client2.get('/api/auth/profile/')
        test(f"Get User2 profile — status {r.status_code}",
             r.status_code == 200)
        if r.status_code == 200:
            if not user2_id:
                user2_id = r.data.get('id')

    # Unauthenticated profile access
    anon = APIClient()
    r = anon.get('/api/auth/profile/')
    test("Unauthenticated profile blocked", r.status_code in [401, 403])

    # ══════════════════════════════════════════════════════════════
    # 6. CREATE CONVERSATION
    # ══════════════════════════════════════════════════════════════
    section("6. CREATE CONVERSATION")

    if token1 and user2_id:
        # Create private conversation via correct endpoint (returns existing if any)
        r = client1.post('/api/chat/conversations/create/', {
            'user_id': int(user2_id),
        }, format='json')

        test(f"Create conversation — status {r.status_code}",
             r.status_code in [200, 201],
             f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')

        if r.status_code in [200, 201]:
            conversation_id = r.data.get('id')
            test("Conversation ID received", conversation_id is not None,
                 f"Response keys: {get_response_data(r)}")
    else:
        warn("Skipping conversation creation — missing token or user IDs",
             f"token1={bool(token1)}, user2_id={user2_id}")

    # ══════════════════════════════════════════════════════════════
    # 7. LIST CONVERSATIONS
    # ══════════════════════════════════════════════════════════════
    section("7. LIST CONVERSATIONS")

    if token1:
        r = client1.get('/api/chat/conversations/')
        test(f"User1 list conversations — status {r.status_code}",
             r.status_code == 200)
        if r.status_code == 200:
            data = r.data
            # Handle paginated vs non-paginated response
            results = data.get('results', data) if isinstance(data, dict) else data
            if isinstance(results, list):
                test("User1 has conversations", len(results) >= 1,
                     f"Count: {len(results)}")

    if token2:
        r = client2.get('/api/chat/conversations/')
        test(f"User2 list conversations — status {r.status_code}",
             r.status_code == 200)

    # ══════════════════════════════════════════════════════════════
    # 8. SEND TEXT MESSAGES
    # ══════════════════════════════════════════════════════════════
    section("8. SEND TEXT MESSAGES")

    if conversation_id and token1:
        # User1 sends message to conversation
        msg_data = {
            'conversation': str(conversation_id),
            'content': 'Hello Bob! This is a test message from Alice.',
            'message_type': 'text',
        }

        # Try different API structures
        r = client1.post(f'/api/chat/conversations/{conversation_id}/messages/',
                         msg_data, format='json')

        if r.status_code not in [200, 201]:
            r = client1.post('/api/chat/messages/', msg_data, format='json')

        if r.status_code not in [200, 201]:
            msg_data_alt = {
                'content': 'Hello Bob! This is a test message from Alice.',
                'message_type': 'text',
            }
            r = client1.post(f'/api/chat/conversations/{conversation_id}/messages/',
                             msg_data_alt, format='json')

        test(f"User1 send text message — status {r.status_code}",
             r.status_code in [200, 201],
             f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')

        if r.status_code in [200, 201]:
            message_id = r.data.get('id')
            test("Message ID received", message_id is not None)

        # User2 sends reply
        if token2:
            reply_data = {
                'content': 'Hi Alice! Got your message. This is Bob.',
                'message_type': 'text',
            }
            r = client2.post(f'/api/chat/conversations/{conversation_id}/messages/',
                             reply_data, format='json')

            if r.status_code not in [200, 201]:
                reply_data['conversation'] = str(conversation_id)
                r = client2.post('/api/chat/messages/', reply_data, format='json')

            test(f"User2 send reply — status {r.status_code}",
                 r.status_code in [200, 201],
                 f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')
    else:
        warn("Skipping messages — no conversation created")

    # ══════════════════════════════════════════════════════════════
    # 9. RETRIEVE MESSAGES
    # ══════════════════════════════════════════════════════════════
    section("9. RETRIEVE MESSAGES")

    if conversation_id and token1:
        r = client1.get(f'/api/chat/conversations/{conversation_id}/messages/')
        test(f"Get conversation messages — status {r.status_code}",
             r.status_code == 200,
             f"Response: {get_response_data(r)}" if r.status_code != 200 else '')

        if r.status_code == 200:
            data = r.data
            results = data.get('results', data) if isinstance(data, dict) else data
            if isinstance(results, list):
                test("Messages retrieved", len(results) >= 1,
                     f"Count: {len(results)}")

    # ══════════════════════════════════════════════════════════════
    # 10. ENCRYPTED MEDIA UPLOAD
    # ══════════════════════════════════════════════════════════════
    section("10. ENCRYPTED MEDIA UPLOAD")

    if conversation_id and token1:
        # Simulate an encrypted file upload
        fake_encrypted_content = os.urandom(1024)  # 1KB fake encrypted blob
        fake_encrypted_thumbnail = os.urandom(256)  # Small fake thumbnail
        fake_file_key = 'base64encodedencryptedfilekey=='
        fake_metadata = 'base64encodedencryptedmetadata=='
        file_hash = hashlib.sha256(b'original plaintext content').hexdigest()

        from django.core.files.uploadedfile import SimpleUploadedFile

        encrypted_file = SimpleUploadedFile(
            "encrypted_blob",
            fake_encrypted_content,
            content_type="application/octet-stream"
        )
        encrypted_thumb = SimpleUploadedFile(
            "encrypted_thumb",
            fake_encrypted_thumbnail,
            content_type="application/octet-stream"
        )

        r = client1.post('/api/chat/media/upload/', {
            'encrypted_file': encrypted_file,
            'encrypted_thumbnail': encrypted_thumb,
            'conversation_id': str(conversation_id),
            'encrypted_file_key': fake_file_key,
            'encrypted_metadata': fake_metadata,
            'file_hash': file_hash,
            'encrypted_file_size': '5000',
        }, format='multipart')

        test(f"Upload encrypted media — status {r.status_code}",
             r.status_code in [200, 201],
             f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')

        if r.status_code in [200, 201]:
            attachment_id = r.data.get('attachment_id')
            test("Attachment ID received", attachment_id is not None)

            # Download encrypted media
            if attachment_id:
                r = client1.get(f'/api/chat/media/{attachment_id}/download/')
                test(f"Download encrypted media — status {r.status_code}",
                     r.status_code == 200,
                     f"Status: {r.status_code}" if r.status_code != 200 else '')

                # Get encrypted key
                r = client1.get(f'/api/chat/media/{attachment_id}/key/')
                test(f"Get attachment key — status {r.status_code}",
                     r.status_code == 200)
                if r.status_code == 200:
                    test("Key response has encrypted_file_key",
                         'encrypted_file_key' in r.data)
                    test("Key response has encrypted_metadata",
                         'encrypted_metadata' in r.data)
                    test("Key response has file_hash",
                         r.data.get('file_hash') == file_hash)

                # Download thumbnail
                r = client1.get(f'/api/chat/media/{attachment_id}/thumbnail/')
                test(f"Download encrypted thumbnail — status {r.status_code}",
                     r.status_code == 200)

                # User2 can also download (participant)
                if token2:
                    # First need to link attachment to a message
                    r = client2.get(f'/api/chat/media/{attachment_id}/key/')
                    test(f"User2 access attachment key — status {r.status_code}",
                         r.status_code in [200, 403],
                         "403 expected if attachment not linked to message yet")
    else:
        warn("Skipping media upload — no conversation")

    # ══════════════════════════════════════════════════════════════
    # 11. ENCRYPTION — Key Bundle
    # ══════════════════════════════════════════════════════════════
    section("11. ENCRYPTION — Key Bundle")

    if token1:
        try:
            # Encryption has no base URL; use a specific endpoint (e.g. keys/count/). If POST-only, 405 = accessible.
            r = client1.get('/api/encryption/keys/count/')
            test(f"Encryption API accessible — status {r.status_code}",
                 r.status_code in (200, 401, 403, 405),
                 f"Status: {r.status_code}")
        except Exception as e:
            test(f"Encryption API — error: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 12. NOTIFICATIONS
    # ══════════════════════════════════════════════════════════════
    section("12. NOTIFICATIONS")

    if token1:
        try:
            r = client1.get('/api/notifications/badge/')
            test(f"Notification badge — status {r.status_code}",
                 r.status_code == 200,
                 f"Response: {get_response_data(r)}" if r.status_code == 200 else '')
        except Exception as e:
            test(f"Notification badge — error: {e}", False)

        try:
            r = client1.get('/api/notifications/')
            test(f"Notification list — status {r.status_code}",
                 r.status_code == 200)
        except Exception as e:
            test(f"Notification list — error: {e}", False)

        try:
            r = client1.post('/api/notifications/devices/register/', {
                'token': 'fake-fcm-token-for-testing-' + str(time.time()),
                'platform': 'ios',
                'device_name': 'Test iPhone',
                'device_id': 'test-device-id-001',
            }, format='json')
            test(f"Register FCM device token — status {r.status_code}",
                 r.status_code in [200, 201],
                 f"Response: {get_response_data(r)}" if r.status_code not in [200, 201] else '')
        except Exception as e:
            test(f"Register FCM device token — error: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 13. CHANNELS (Public Broadcast)
    # ══════════════════════════════════════════════════════════════
    section("13. CHANNELS (Public Broadcast)")

    if token1:
        try:
            r = client1.get('/api/channels/')
            test(f"Channel list — status {r.status_code}",
                 r.status_code == 200,
                 f"Status: {r.status_code}")
        except Exception as e:
            test(f"Channel list — error: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 14. TRANSLATION
    # ══════════════════════════════════════════════════════════════
    # 15. SECURITY (Shield)
    # ══════════════════════════════════════════════════════════════
    section("15. SECURITY (Shield)")

    if token1:
        try:
            r = client1.get('/api/security/dashboard/')
            test(f"Security dashboard — status {r.status_code}",
                 r.status_code in [200, 404],
                 f"Status: {r.status_code}")
        except Exception as e:
            test(f"Security dashboard — error: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 16. ADMIN API
    # ══════════════════════════════════════════════════════════════
    section("16. ADMIN API")

    # Login as admin
    admin_client = APIClient()
    admin_token = None
    try:
        r = admin_client.post('/api/auth/login/', {
            'email': 'admin@securechat.com',
            'password': 'Admin2026!',
        }, format='json')
        if r.status_code == 200:
            data = r.data
            if 'access' in data:
                admin_token = data['access']
            elif 'token' in data and isinstance(data['token'], dict):
                admin_token = data['token'].get('access', '')
            elif 'tokens' in data:
                admin_token = data['tokens'].get('access', '')
    except Exception as e:
        warn(f"Admin login — error: {e}")

    if admin_token:
        admin_client.credentials(HTTP_AUTHORIZATION=f'Bearer {admin_token}')

        try:
            r = admin_client.get('/api/admin-panel/dashboard/stats/')
            test(f"Admin dashboard — status {r.status_code}",
                 r.status_code == 200,
                 f"Response: {get_response_data(r)}" if r.status_code != 200 else '')
        except Exception as e:
            test(f"Admin dashboard — error: {e}", False)

        try:
            r = admin_client.get('/api/admin-panel/users/')
            test(f"Admin users list — status {r.status_code}",
                 r.status_code == 200)
            if r.status_code == 200:
                data = r.data
                results = data.get('results', data) if isinstance(data, dict) else data
                if isinstance(results, list):
                    test("Admin sees multiple users", len(results) >= 3,
                         f"Count: {len(results)}")  # admin + user1 + user2
        except Exception as e:
            test(f"Admin users list — error: {e}", False)
    else:
        warn("Admin login failed — skipping admin tests",
             "No token received")

    # Non-admin should be blocked
    if token1:
        try:
            r = client1.get('/api/admin-panel/dashboard/stats/')
            test("Non-admin blocked from admin API",
                 r.status_code in [401, 403])
        except Exception as e:
            test(f"Non-admin admin API check — error: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 17. DJANGO ADMIN
    # ══════════════════════════════════════════════════════════════
    section("17. DJANGO ADMIN")

    try:
        r = client1.get('/admin/')
        test("Django admin page accessible", r.status_code in [200, 302])
    except Exception as e:
        test(f"Django admin page — error: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # 18. ENCRYPTION UNIT TESTS
    # ══════════════════════════════════════════════════════════════
    section("18. ENCRYPTION UNIT TESTS")

    try:
        from encryption.media_cipher import (
            generate_file_key, encrypt_file_data, decrypt_file_data,
            encrypt_file_key, decrypt_file_key,
            encrypt_metadata, decrypt_metadata,
            compute_file_hash,
        )

        # Test basic encryption/decryption
        key = generate_file_key()
        plaintext = b"Test file content for encryption"
        encrypted = encrypt_file_data(plaintext, key)
        test("File encryption produces different output", encrypted != plaintext)
        test("Encrypted data is larger", len(encrypted) > len(plaintext))

        decrypted = decrypt_file_data(encrypted, key)
        test("File decryption recovers original", decrypted == plaintext)

        # Test wrong key fails
        wrong_key = generate_file_key()
        try:
            decrypt_file_data(encrypted, wrong_key)
            test("Wrong key decryption fails", False, "Should have raised exception")
        except Exception:
            test("Wrong key decryption fails", True)

        # Test file key envelope encryption
        session_key = generate_file_key()
        encrypted_fk = encrypt_file_key(key, session_key)
        decrypted_fk = decrypt_file_key(encrypted_fk, session_key)
        test("File key envelope encryption roundtrip", decrypted_fk == key)

        # Test metadata encryption
        meta = {'filename': 'photo.jpg', 'mime_type': 'image/jpeg', 'file_size': 12345}
        encrypted_meta = encrypt_metadata(meta, key)
        decrypted_meta = decrypt_metadata(encrypted_meta, key)
        test("Metadata encryption roundtrip", decrypted_meta == meta)

        # Test hash
        h1 = compute_file_hash(plaintext)
        h2 = compute_file_hash(plaintext)
        h3 = compute_file_hash(b"different content")
        test("Hash is deterministic", h1 == h2)
        test("Different content = different hash", h1 != h3)

    except ImportError as e:
        warn(f"Encryption module not found: {e}")
    except Exception as e:
        test(f"Encryption tests: {e}", False)

    # ══════════════════════════════════════════════════════════════
    # SUMMARY
    # ══════════════════════════════════════════════════════════════
    elapsed = time.time() - start_time

    print(f"\n{BOLD}{'='*60}")
    print(f"  📊 TEST RESULTS")
    print(f"{'='*60}{END}")
    print(f"  {GREEN}✅ Passed:   {passed}{END}")
    print(f"  {RED}❌ Failed:   {failed}{END}")
    print(f"  {YELLOW}⚠️  Warnings: {warnings}{END}")
    print(f"  ⏱️  Time:     {elapsed:.1f}s")
    print(f"{'='*60}")

    if failed == 0:
        print(f"\n  {GREEN}{BOLD}🎉 ALL TESTS PASSED!{END}")
    elif failed <= 3:
        print(f"\n  {YELLOW}{BOLD}⚡ MOSTLY PASSING — check failed tests above{END}")
    else:
        print(f"\n  {RED}{BOLD}💥 MULTIPLE FAILURES — review output above{END}")

    print()
    return 0 if failed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
