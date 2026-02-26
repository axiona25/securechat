"""Test suite for crypto_version=2 (X25519/Ed25519) support."""
import base64
from django.test import TestCase
from encryption.scp_keys import (
    generate_identity_keypair_v2,
    generate_identity_dh_keypair_v2,
    generate_signed_prekey_v2,
    verify_signed_prekey_v2,
    generate_one_time_prekeys_v2,
    x25519_dh,
    x3dh_sender_v2,
    x3dh_receiver_v2,
    generate_full_key_bundle,
    perform_x3dh_sender,
    perform_x3dh_receiver,
    generate_safety_number_v2,
)


class TestKeyGenerationV2(TestCase):
    """Test Ed25519/X25519 key generation."""

    def test_identity_keypair(self):
        kp = generate_identity_keypair_v2()
        self.assertEqual(len(kp['private_key']), 32)
        self.assertEqual(len(kp['public_key']), 32)
        self.assertEqual(kp['algorithm'], 'Ed25519')
        self.assertEqual(kp['crypto_version'], 2)

    def test_identity_dh_keypair(self):
        kp = generate_identity_dh_keypair_v2()
        self.assertEqual(len(kp['private_key']), 32)
        self.assertEqual(len(kp['public_key']), 32)
        self.assertEqual(kp['algorithm'], 'X25519')

    def test_signed_prekey(self):
        identity = generate_identity_keypair_v2()
        spk = generate_signed_prekey_v2(identity['private_key'])
        self.assertEqual(len(spk['private_key']), 32)
        self.assertEqual(len(spk['public_key']), 32)
        self.assertEqual(len(spk['signature']), 64)

        # Verify signature
        self.assertTrue(verify_signed_prekey_v2(
            identity_public_key_bytes=identity['public_key'],
            signed_prekey_public_bytes=spk['public_key'],
            signature=spk['signature'],
            timestamp=spk['timestamp'],
        ))

    def test_signed_prekey_wrong_key_fails(self):
        identity1 = generate_identity_keypair_v2()
        identity2 = generate_identity_keypair_v2()
        spk = generate_signed_prekey_v2(identity1['private_key'])

        # Verify with wrong identity key should fail
        self.assertFalse(verify_signed_prekey_v2(
            identity_public_key_bytes=identity2['public_key'],
            signed_prekey_public_bytes=spk['public_key'],
            signature=spk['signature'],
            timestamp=spk['timestamp'],
        ))

    def test_one_time_prekeys(self):
        prekeys = generate_one_time_prekeys_v2(count=10)
        self.assertEqual(len(prekeys), 10)
        for pk in prekeys:
            self.assertEqual(len(pk['private_key']), 32)
            self.assertEqual(len(pk['public_key']), 32)


class TestX25519DH(TestCase):
    """Test X25519 Diffie-Hellman."""

    def test_dh_shared_secret(self):
        alice = generate_identity_dh_keypair_v2()
        bob = generate_identity_dh_keypair_v2()

        secret_a = x25519_dh(alice['private_key'], bob['public_key'])
        secret_b = x25519_dh(bob['private_key'], alice['public_key'])

        self.assertEqual(secret_a, secret_b)
        self.assertEqual(len(secret_a), 32)


class TestX3DHV2(TestCase):
    """Test X3DH key agreement (crypto_version=2)."""

    def test_x3dh_with_one_time_prekey(self):
        # Alice (sender) generates ephemeral + has identity
        alice_identity = generate_identity_keypair_v2()
        alice_identity_dh = generate_identity_dh_keypair_v2()
        alice_ephemeral = generate_identity_dh_keypair_v2()

        # Bob (receiver) has full key bundle
        bob_identity = generate_identity_keypair_v2()
        bob_identity_dh = generate_identity_dh_keypair_v2()
        bob_signed_prekey = generate_signed_prekey_v2(bob_identity['private_key'])
        bob_otpks = generate_one_time_prekeys_v2(count=1)

        # Alice computes shared secret
        secret_alice = x3dh_sender_v2(
            sender_identity_dh_private=alice_identity_dh['private_key'],
            sender_ephemeral_private=alice_ephemeral['private_key'],
            receiver_identity_dh_public=bob_identity_dh['public_key'],
            receiver_signed_prekey_public=bob_signed_prekey['public_key'],
            receiver_one_time_prekey_public=bob_otpks[0]['public_key'],
        )

        # Bob computes shared secret
        secret_bob = x3dh_receiver_v2(
            receiver_identity_dh_private=bob_identity_dh['private_key'],
            receiver_signed_prekey_private=bob_signed_prekey['private_key'],
            sender_identity_dh_public=alice_identity_dh['public_key'],
            sender_ephemeral_public=alice_ephemeral['public_key'],
            receiver_one_time_prekey_private=bob_otpks[0]['private_key'],
        )

        self.assertEqual(secret_alice, secret_bob)
        self.assertEqual(len(secret_alice), 32)

    def test_x3dh_without_one_time_prekey(self):
        alice_identity_dh = generate_identity_dh_keypair_v2()
        alice_ephemeral = generate_identity_dh_keypair_v2()

        bob_identity = generate_identity_keypair_v2()
        bob_identity_dh = generate_identity_dh_keypair_v2()
        bob_signed_prekey = generate_signed_prekey_v2(bob_identity['private_key'])

        secret_alice = x3dh_sender_v2(
            sender_identity_dh_private=alice_identity_dh['private_key'],
            sender_ephemeral_private=alice_ephemeral['private_key'],
            receiver_identity_dh_public=bob_identity_dh['public_key'],
            receiver_signed_prekey_public=bob_signed_prekey['public_key'],
        )

        secret_bob = x3dh_receiver_v2(
            receiver_identity_dh_private=bob_identity_dh['private_key'],
            receiver_signed_prekey_private=bob_signed_prekey['private_key'],
            sender_identity_dh_public=alice_identity_dh['public_key'],
            sender_ephemeral_public=alice_ephemeral['public_key'],
        )

        self.assertEqual(secret_alice, secret_bob)


class TestFullKeyBundle(TestCase):
    """Test the version-aware wrapper."""

    def test_generate_bundle_v2(self):
        bundle = generate_full_key_bundle(crypto_version=2)
        self.assertEqual(bundle['crypto_version'], 2)
        self.assertEqual(len(bundle['identity']['public_key']), 32)
        self.assertEqual(len(bundle['identity_dh']['public_key']), 32)
        self.assertEqual(len(bundle['signed_prekey']['public_key']), 32)
        self.assertEqual(len(bundle['one_time_prekeys']), 100)

    def test_generate_bundle_v1(self):
        bundle = generate_full_key_bundle(crypto_version=1)
        self.assertEqual(bundle['crypto_version'], 1)
        # X448/Ed448 keys are larger
        self.assertEqual(len(bundle['identity']['public_key']), 57)
        self.assertEqual(len(bundle['identity_dh']['public_key']), 56)


class TestSafetyNumberV2(TestCase):
    """Test safety number generation."""

    def test_safety_number_symmetric(self):
        alice = generate_identity_keypair_v2()
        bob = generate_identity_keypair_v2()

        sn1 = generate_safety_number_v2(alice['public_key'], bob['public_key'], 1, 2)
        sn2 = generate_safety_number_v2(bob['public_key'], alice['public_key'], 2, 1)

        self.assertEqual(sn1, sn2)
        # 60 digits + 11 spaces = 71 chars
        self.assertEqual(len(sn1), 71)
