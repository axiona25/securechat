"""Tests for media encryption/decryption."""
import os

from django.test import TestCase

from encryption.media_cipher import (
    generate_file_key,
    encrypt_file_data,
    decrypt_file_data,
    encrypt_file_key,
    decrypt_file_key,
    encrypt_metadata,
    decrypt_metadata,
    compute_file_hash,
)


class MediaCipherTestCase(TestCase):
    """Test media encryption functions."""

    def test_encrypt_decrypt_small_file(self):
        """Test encrypting and decrypting a small file."""
        file_key = generate_file_key()
        plaintext = b"Hello, this is a test file content!"

        encrypted = encrypt_file_data(plaintext, file_key)
        self.assertNotEqual(encrypted, plaintext)
        self.assertGreater(len(encrypted), len(plaintext))

        decrypted = decrypt_file_data(encrypted, file_key)
        self.assertEqual(decrypted, plaintext)

    def test_encrypt_decrypt_large_file(self):
        """Test chunked encryption for files > 5MB."""
        file_key = generate_file_key()
        plaintext = os.urandom(6 * 1024 * 1024)

        encrypted = encrypt_file_data(plaintext, file_key)
        self.assertTrue(encrypted[:4] == b'SCM\x01')

        decrypted = decrypt_file_data(encrypted, file_key)
        self.assertEqual(decrypted, plaintext)

    def test_wrong_key_fails(self):
        """Test that decryption with wrong key raises error."""
        file_key = generate_file_key()
        wrong_key = generate_file_key()
        plaintext = b"Secret content"

        encrypted = encrypt_file_data(plaintext, file_key)

        with self.assertRaises(Exception):
            decrypt_file_data(encrypted, wrong_key)

    def test_encrypt_decrypt_file_key(self):
        """Test envelope encryption of file key with session key."""
        file_key = generate_file_key()
        session_key = generate_file_key()

        encrypted_fk = encrypt_file_key(file_key, session_key)
        decrypted_fk = decrypt_file_key(encrypted_fk, session_key)

        self.assertEqual(decrypted_fk, file_key)

    def test_encrypt_decrypt_metadata(self):
        """Test metadata encryption."""
        file_key = generate_file_key()
        metadata = {
            'filename': 'photo.jpg',
            'mime_type': 'image/jpeg',
            'file_size': 1234567,
            'width': 1920,
            'height': 1080,
        }

        encrypted_meta = encrypt_metadata(metadata, file_key)
        decrypted_meta = decrypt_metadata(encrypted_meta, file_key)

        self.assertEqual(decrypted_meta, metadata)

    def test_file_hash(self):
        """Test SHA-256 hash computation."""
        data = b"test data for hashing"
        hash1 = compute_file_hash(data)
        hash2 = compute_file_hash(data)

        self.assertEqual(hash1, hash2)
        self.assertEqual(len(hash1), 64)

        hash3 = compute_file_hash(b"different data")
        self.assertNotEqual(hash1, hash3)

    def test_aad_prevents_tampering(self):
        """Test that AAD prevents cross-context attacks."""
        file_key = generate_file_key()
        plaintext = b"test"

        encrypted = encrypt_file_data(plaintext, file_key, aad=b"context-1")

        with self.assertRaises(Exception):
            decrypt_file_data(encrypted, file_key, aad=b"context-2")

        decrypted = decrypt_file_data(encrypted, file_key, aad=b"context-1")
        self.assertEqual(decrypted, plaintext)

    def test_binary_file_types(self):
        """Test encryption of various binary file sizes."""
        file_key = generate_file_key()

        for size in [1, 100, 1024, 1024 * 100]:
            plaintext = os.urandom(size)
            encrypted = encrypt_file_data(plaintext, file_key)
            decrypted = decrypt_file_data(encrypted, file_key)
            self.assertEqual(decrypted, plaintext, f"Failed for size {size}")
