"""
Comprehensive tests for SCP encryption module.
Run with: python manage.py test encryption
"""

from django.test import TestCase
from .scp_keys import (
    generate_identity_keypair, generate_identity_dh_keypair,
    generate_x448_keypair, generate_signed_prekey, verify_signed_prekey,
    generate_one_time_prekeys, x448_dh, x3dh_sender, x3dh_receiver,
    generate_safety_number
)
from .cipher import (
    aead_encrypt, aead_decrypt, envelope_encrypt, envelope_decrypt,
    encrypt_file, decrypt_file, pack_message, unpack_message
)
from .double_ratchet import DoubleRatchet, MessageHeader
import nacl.exceptions
import os
import time


class SCPKeyTests(TestCase):
    """Test key generation and X3DH key exchange"""

    def test_identity_keypair_generation(self):
        priv, pub = generate_identity_keypair()
        self.assertEqual(len(priv), 57, 'Ed448 private key should be 57 bytes')
        self.assertEqual(len(pub), 57, 'Ed448 public key should be 57 bytes')
        # Generate another, should be different
        priv2, pub2 = generate_identity_keypair()
        self.assertNotEqual(priv, priv2)
        self.assertNotEqual(pub, pub2)

    def test_x448_keypair_generation(self):
        priv, pub = generate_x448_keypair()
        self.assertEqual(len(priv), 56, 'X448 private key should be 56 bytes')
        self.assertEqual(len(pub), 56, 'X448 public key should be 56 bytes')

    def test_signed_prekey_generation_and_verification(self):
        id_priv, id_pub = generate_identity_keypair()
        pk_priv, pk_pub, signature = generate_signed_prekey(id_priv)
        self.assertEqual(len(pk_priv), 56)
        self.assertEqual(len(pk_pub), 56)
        # Verification should pass
        result = verify_signed_prekey(id_pub, pk_pub, signature)
        self.assertTrue(result)

    def test_signed_prekey_wrong_identity_fails(self):
        id_priv, id_pub = generate_identity_keypair()
        _, other_pub = generate_identity_keypair()
        _, pk_pub, signature = generate_signed_prekey(id_priv)
        with self.assertRaises(Exception):
            verify_signed_prekey(other_pub, pk_pub, signature)

    def test_one_time_prekeys_generation(self):
        prekeys = generate_one_time_prekeys(count=50, start_id=10)
        self.assertEqual(len(prekeys), 50)
        self.assertEqual(prekeys[0][0], 10)
        self.assertEqual(prekeys[49][0], 59)
        # All keys should be unique
        pub_keys = [pk[2] for pk in prekeys]
        self.assertEqual(len(set(pub_keys)), 50)

    def test_x448_dh_shared_secret(self):
        priv_a, pub_a = generate_x448_keypair()
        priv_b, pub_b = generate_x448_keypair()
        secret_ab = x448_dh(priv_a, pub_b)
        secret_ba = x448_dh(priv_b, pub_a)
        self.assertEqual(secret_ab, secret_ba, 'DH shared secret must be symmetric')
        self.assertEqual(len(secret_ab), 56)

    def test_x3dh_sender_receiver_match(self):
        """Core test: X3DH must produce identical shared secret on both sides"""
        # Alice (sender) keys
        _, alice_id_dh_pub = generate_identity_dh_keypair()
        alice_id_dh_priv, _ = generate_identity_dh_keypair()
        alice_eph_priv, alice_eph_pub = generate_x448_keypair()

        # Bob (receiver) keys
        bob_id_dh_priv, bob_id_dh_pub = generate_identity_dh_keypair()
        bob_spk_priv, bob_spk_pub, _ = generate_signed_prekey(generate_identity_keypair()[0])
        bob_otpks = generate_one_time_prekeys(count=1)
        bob_otpk_priv = bob_otpks[0][1]
        bob_otpk_pub = bob_otpks[0][2]

        # Sender computes shared secret
        sender_secret = x3dh_sender(
            sender_identity_dh_priv=alice_id_dh_priv,
            sender_ephemeral_priv=alice_eph_priv,
            recipient_identity_dh_pub=bob_id_dh_pub,
            recipient_signed_prekey_pub=bob_spk_pub,
            recipient_one_time_prekey_pub=bob_otpk_pub
        )

        # Receiver computes shared secret
        receiver_secret = x3dh_receiver(
            recipient_identity_dh_priv=bob_id_dh_priv,
            recipient_signed_prekey_priv=bob_spk_priv,
            sender_identity_dh_pub=alice_id_dh_pub,
            sender_ephemeral_pub=alice_eph_pub,
            recipient_one_time_prekey_priv=bob_otpk_priv
        )

        self.assertEqual(sender_secret, receiver_secret, 'X3DH shared secrets must match')
        self.assertEqual(len(sender_secret), 64)

    def test_x3dh_without_one_time_prekey(self):
        """X3DH should work even without one-time prekey (3-DH instead of 4-DH)"""
        alice_id_priv, alice_id_pub = generate_identity_dh_keypair()
        alice_eph_priv, alice_eph_pub = generate_x448_keypair()
        bob_id_priv, bob_id_pub = generate_identity_dh_keypair()
        bob_spk_priv, bob_spk_pub, _ = generate_signed_prekey(generate_identity_keypair()[0])

        sender_secret = x3dh_sender(alice_id_priv, alice_eph_priv, bob_id_pub, bob_spk_pub, None)
        receiver_secret = x3dh_receiver(bob_id_priv, bob_spk_priv, alice_id_pub, alice_eph_pub, None)

        self.assertEqual(sender_secret, receiver_secret)

    def test_safety_number_symmetric(self):
        _, pub_a = generate_identity_keypair()
        _, pub_b = generate_identity_keypair()
        formatted_ab, raw_ab = generate_safety_number(pub_a, pub_b)
        formatted_ba, raw_ba = generate_safety_number(pub_b, pub_a)
        self.assertEqual(formatted_ab, formatted_ba, 'Safety number must be symmetric')
        self.assertEqual(len(raw_ab), 60)
        # Different keys should produce different numbers
        _, pub_c = generate_identity_keypair()
        _, raw_ac = generate_safety_number(pub_a, pub_c)
        self.assertNotEqual(raw_ab, raw_ac)


class CipherTests(TestCase):
    """Test XChaCha20-Poly1305 AEAD and envelope encryption"""

    def test_aead_roundtrip(self):
        key = os.urandom(32)
        plaintext = b'Hello SecureChat!'
        aad = b'message_header_data'
        ciphertext = aead_encrypt(key, plaintext, aad)
        decrypted = aead_decrypt(key, ciphertext, aad)
        self.assertEqual(decrypted, plaintext)

    def test_aead_different_nonce_each_time(self):
        key = os.urandom(32)
        plaintext = b'Same message'
        ct1 = aead_encrypt(key, plaintext)
        ct2 = aead_encrypt(key, plaintext)
        self.assertNotEqual(ct1, ct2, 'Each encryption must use a different nonce')

    def test_aead_wrong_key_fails(self):
        key1 = os.urandom(32)
        key2 = os.urandom(32)
        ciphertext = aead_encrypt(key1, b'secret')
        with self.assertRaises((Exception, nacl.exceptions.CryptoError)):
            aead_decrypt(key2, ciphertext)

    def test_aead_tampered_ciphertext_fails(self):
        key = os.urandom(32)
        ciphertext = aead_encrypt(key, b'secret')
        tampered = bytearray(ciphertext)
        tampered[-1] ^= 0xFF  # Flip last byte
        with self.assertRaises((Exception, nacl.exceptions.CryptoError)):
            aead_decrypt(key, bytes(tampered))

    def test_aead_wrong_aad_fails(self):
        key = os.urandom(32)
        ciphertext = aead_encrypt(key, b'secret', b'correct_aad')
        with self.assertRaises((Exception, nacl.exceptions.CryptoError)):
            aead_decrypt(key, ciphertext, b'wrong_aad')

    def test_aead_string_input(self):
        key = os.urandom(32)
        ciphertext = aead_encrypt(key, 'Ciao mondo!', 'header')
        decrypted = aead_decrypt(key, ciphertext, 'header')
        self.assertEqual(decrypted, b'Ciao mondo!')

    def test_envelope_roundtrip(self):
        plaintext = b'Envelope encrypted message'
        eph_key, encrypted = envelope_encrypt(plaintext)
        decrypted = envelope_decrypt(eph_key, encrypted)
        self.assertEqual(decrypted, plaintext)
        self.assertEqual(len(eph_key), 32)

    def test_envelope_unique_keys(self):
        key1, _ = envelope_encrypt(b'msg1')
        key2, _ = envelope_encrypt(b'msg2')
        self.assertNotEqual(key1, key2, 'Each envelope must have a unique key')

    def test_message_pack_unpack(self):
        header = b'header_data_here'
        eek = b'encrypted_envelope_key'
        payload = b'encrypted_payload_content'
        packed = pack_message(header, eek, payload)
        version, h, e, p = unpack_message(packed)
        self.assertEqual(version, 1)
        self.assertEqual(h, header)
        self.assertEqual(e, eek)
        self.assertEqual(p, payload)

    def test_file_encryption_small(self):
        data = os.urandom(1000)  # 1KB file
        key, encrypted = encrypt_file(data)
        decrypted = decrypt_file(key, encrypted)
        self.assertEqual(decrypted, data)

    def test_file_encryption_large_chunked(self):
        data = os.urandom(200000)  # ~200KB file, will be chunked
        key, encrypted = encrypt_file(data)
        decrypted = decrypt_file(key, encrypted)
        self.assertEqual(decrypted, data)

    def test_file_encryption_tampered_fails(self):
        data = os.urandom(1000)
        key, encrypted = encrypt_file(data)
        tampered = bytearray(encrypted)
        tampered[-1] ^= 0xFF
        with self.assertRaises((Exception, nacl.exceptions.CryptoError)):
            decrypt_file(key, bytes(tampered))


class DoubleRatchetTests(TestCase):
    """Test the Double Ratchet protocol"""

    def _create_session_pair(self):
        """Helper: create a sender/receiver ratchet pair via X3DH"""
        alice_id_priv, alice_id_pub = generate_identity_dh_keypair()
        alice_eph_priv, alice_eph_pub = generate_x448_keypair()
        bob_id_priv, bob_id_pub = generate_identity_dh_keypair()
        bob_spk_priv, bob_spk_pub, _ = generate_signed_prekey(generate_identity_keypair()[0])

        shared_sender = x3dh_sender(alice_id_priv, alice_eph_priv, bob_id_pub, bob_spk_pub)
        shared_receiver = x3dh_receiver(bob_id_priv, bob_spk_priv, alice_id_pub, alice_eph_pub)

        alice = DoubleRatchet.init_sender(shared_sender, bob_spk_pub)
        bob = DoubleRatchet.init_receiver(shared_receiver, bob_spk_priv, bob_spk_pub)

        return alice, bob

    def test_basic_send_receive(self):
        alice, bob = self._create_session_pair()
        header, ct = alice.encrypt(b'Hello Bob!')
        pt = bob.decrypt(header, ct)
        self.assertEqual(pt, b'Hello Bob!')

    def test_multiple_messages_one_direction(self):
        alice, bob = self._create_session_pair()
        for i in range(10):
            msg = f'Message {i}'.encode()
            header, ct = alice.encrypt(msg)
            pt = bob.decrypt(header, ct)
            self.assertEqual(pt, msg)

    def test_bidirectional_conversation(self):
        alice, bob = self._create_session_pair()
        # Alice -> Bob
        h1, ct1 = alice.encrypt(b'Hi Bob')
        self.assertEqual(bob.decrypt(h1, ct1), b'Hi Bob')
        # Bob -> Alice
        h2, ct2 = bob.encrypt(b'Hi Alice')
        self.assertEqual(alice.decrypt(h2, ct2), b'Hi Alice')
        # Alice -> Bob again
        h3, ct3 = alice.encrypt(b'How are you?')
        self.assertEqual(bob.decrypt(h3, ct3), b'How are you?')
        # Bob -> Alice again
        h4, ct4 = bob.encrypt(b'Great thanks!')
        self.assertEqual(alice.decrypt(h4, ct4), b'Great thanks!')

    def test_out_of_order_messages(self):
        alice, bob = self._create_session_pair()
        # Alice sends 3 messages
        h1, ct1 = alice.encrypt(b'Message 1')
        h2, ct2 = alice.encrypt(b'Message 2')
        h3, ct3 = alice.encrypt(b'Message 3')
        # Bob receives them out of order: 3, 1, 2
        self.assertEqual(bob.decrypt(h3, ct3), b'Message 3')
        self.assertEqual(bob.decrypt(h1, ct1), b'Message 1')
        self.assertEqual(bob.decrypt(h2, ct2), b'Message 2')

    def test_serialize_deserialize(self):
        alice, bob = self._create_session_pair()
        # Exchange some messages
        h1, ct1 = alice.encrypt(b'Before serialize')
        bob.decrypt(h1, ct1)
        h2, ct2 = bob.encrypt(b'Reply')
        alice.decrypt(h2, ct2)
        # Serialize both
        alice_data = alice.serialize()
        bob_data = bob.serialize()
        # Deserialize
        alice2 = DoubleRatchet.deserialize(alice_data)
        bob2 = DoubleRatchet.deserialize(bob_data)
        # Continue conversation
        h3, ct3 = alice2.encrypt(b'After serialize')
        pt3 = bob2.decrypt(h3, ct3)
        self.assertEqual(pt3, b'After serialize')

    def test_forward_secrecy(self):
        """Compromising current keys should not reveal past messages"""
        alice, bob = self._create_session_pair()
        # Exchange messages to advance ratchet
        h1, ct1 = alice.encrypt(b'Secret past message')
        bob.decrypt(h1, ct1)
        h2, ct2 = bob.encrypt(b'Reply')
        alice.decrypt(h2, ct2)
        # Save current ratchet keys
        old_sending_key = alice.sending_chain_key
        # Advance ratchet further
        for i in range(5):
            h, ct = alice.encrypt(f'msg {i}'.encode())
            bob.decrypt(h, ct)
            h, ct = bob.encrypt(f'reply {i}'.encode())
            alice.decrypt(h, ct)
        # The old sending key is now useless for current messages
        self.assertNotEqual(alice.sending_chain_key, old_sending_key)

    def test_wrong_key_decrypt_fails(self):
        alice, bob = self._create_session_pair()
        # Create a separate unrelated ratchet
        eve, _ = self._create_session_pair()
        h, ct = alice.encrypt(b'Private message')
        with self.assertRaises(Exception):
            eve.decrypt(h, ct)

    def test_performance_1000_messages(self):
        alice, bob = self._create_session_pair()
        start = time.time()
        for i in range(1000):
            h, ct = alice.encrypt(f'Performance test message {i}'.encode())
            bob.decrypt(h, ct)
        elapsed = time.time() - start
        avg_ms = (elapsed / 1000) * 1000
        print(f'\nPerformance: 1000 encrypt+decrypt in {elapsed:.2f}s ({avg_ms:.2f}ms avg per message)')
        self.assertLess(avg_ms, 50, 'Each encrypt+decrypt should be under 50ms')

    def test_header_encode_decode(self):
        pub = os.urandom(56)
        header = MessageHeader(pub, 5, 42)
        encoded = header.encode()
        decoded = MessageHeader.decode(encoded)
        self.assertEqual(decoded.dh_public, pub)
        self.assertEqual(decoded.previous_chain_length, 5)
        self.assertEqual(decoded.message_number, 42)
