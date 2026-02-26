"""
SecureChat — Media E2EE Encryption
Cifra/decifra media e allegati con XChaCha20-Poly1305 via nacl.bindings.
Usa lo stesso approccio di cipher.py per coerenza.
"""
import os
import json
import hashlib
from typing import Tuple, Optional, Dict, Any

from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_encrypt,
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_aead_xchacha20poly1305_ietf_NPUBBYTES,  # 24
    crypto_aead_xchacha20poly1305_ietf_KEYBYTES,    # 32
)

NONCE_SIZE = crypto_aead_xchacha20poly1305_ietf_NPUBBYTES  # 24 bytes
KEY_SIZE = crypto_aead_xchacha20poly1305_ietf_KEYBYTES      # 32 bytes
# Chunk size for streaming encryption (5MB chunks for large files)
CHUNK_SIZE = 5 * 1024 * 1024


def generate_file_key() -> bytes:
    """Generate a random 32-byte symmetric key for file encryption."""
    return os.urandom(KEY_SIZE)


def encrypt_file_data(plaintext: bytes, file_key: bytes, aad: Optional[bytes] = None) -> bytes:
    """
    Encrypt file data with XChaCha20-Poly1305.

    Returns: nonce (24 bytes) + ciphertext (with 16-byte Poly1305 tag appended)

    For files <= CHUNK_SIZE: single-shot encryption.
    For files > CHUNK_SIZE: chunked encryption with chunk index in AAD.
    """
    if len(file_key) != KEY_SIZE:
        raise ValueError(f"file_key must be {KEY_SIZE} bytes, got {len(file_key)}")

    if len(plaintext) <= CHUNK_SIZE:
        # Single-shot encryption for small files
        nonce = os.urandom(NONCE_SIZE)
        ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(
            plaintext,
            aad or b'',
            nonce,
            file_key,
        )
        return nonce + ciphertext
    else:
        # Chunked encryption for large files
        return _encrypt_chunked(plaintext, file_key, aad)


def decrypt_file_data(encrypted_data: bytes, file_key: bytes, aad: Optional[bytes] = None) -> bytes:
    """
    Decrypt file data encrypted with encrypt_file_data().

    Input: nonce (24 bytes) + ciphertext
    Returns: plaintext bytes
    """
    if len(file_key) != KEY_SIZE:
        raise ValueError(f"file_key must be {KEY_SIZE} bytes, got {len(file_key)}")

    if len(encrypted_data) < NONCE_SIZE + 16:  # nonce + minimum Poly1305 tag
        raise ValueError("Encrypted data too short")

    # Check if this is chunked data (starts with magic bytes)
    if encrypted_data[:4] == b'SCM\x01':  # SecureChat Media v1
        return _decrypt_chunked(encrypted_data, file_key, aad)

    # Single-shot decryption
    nonce = encrypted_data[:NONCE_SIZE]
    ciphertext = encrypted_data[NONCE_SIZE:]

    return crypto_aead_xchacha20poly1305_ietf_decrypt(
        ciphertext,
        aad or b'',
        nonce,
        file_key,
    )


def _encrypt_chunked(plaintext: bytes, file_key: bytes, aad: Optional[bytes] = None) -> bytes:
    """Chunked encryption for large files. Format: magic(4) + chunk_count(4) + [nonce+ciphertext]..."""
    chunks = []
    offset = 0
    chunk_index = 0

    while offset < len(plaintext):
        chunk = plaintext[offset:offset + CHUNK_SIZE]
        # Include chunk index in AAD to prevent reordering
        chunk_aad = (aad or b'') + chunk_index.to_bytes(4, 'big')
        nonce = os.urandom(NONCE_SIZE)
        ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(
            chunk,
            chunk_aad,
            nonce,
            file_key,
        )
        # Each chunk: nonce_size(4) + nonce + ct_size(4) + ciphertext
        chunk_data = (
            len(nonce).to_bytes(4, 'big') + nonce +
            len(ciphertext).to_bytes(4, 'big') + ciphertext
        )
        chunks.append(chunk_data)
        offset += CHUNK_SIZE
        chunk_index += 1

    # Header: magic + chunk_count
    header = b'SCM\x01' + len(chunks).to_bytes(4, 'big')
    return header + b''.join(chunks)


def _decrypt_chunked(encrypted_data: bytes, file_key: bytes, aad: Optional[bytes] = None) -> bytes:
    """Decrypt chunked encrypted data."""
    if encrypted_data[:4] != b'SCM\x01':
        raise ValueError("Invalid chunked encryption header")

    chunk_count = int.from_bytes(encrypted_data[4:8], 'big')
    offset = 8
    plaintext_chunks = []

    for chunk_index in range(chunk_count):
        chunk_aad = (aad or b'') + chunk_index.to_bytes(4, 'big')

        nonce_size = int.from_bytes(encrypted_data[offset:offset + 4], 'big')
        offset += 4
        nonce = encrypted_data[offset:offset + nonce_size]
        offset += nonce_size

        ct_size = int.from_bytes(encrypted_data[offset:offset + 4], 'big')
        offset += 4
        ciphertext = encrypted_data[offset:offset + ct_size]
        offset += ct_size

        plaintext = crypto_aead_xchacha20poly1305_ietf_decrypt(
            ciphertext,
            chunk_aad,
            nonce,
            file_key,
        )
        plaintext_chunks.append(plaintext)

    return b''.join(plaintext_chunks)


def encrypt_file_key(file_key: bytes, session_key: bytes) -> bytes:
    """
    Encrypt the file_key with the E2EE session key (envelope encryption).
    This is what gets sent in the message payload.
    """
    nonce = os.urandom(NONCE_SIZE)
    ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(
        file_key,
        b'securechat-file-key',
        nonce,
        session_key,
    )
    return nonce + ciphertext


def decrypt_file_key(encrypted_file_key: bytes, session_key: bytes) -> bytes:
    """Decrypt the file_key using the E2EE session key."""
    nonce = encrypted_file_key[:NONCE_SIZE]
    ciphertext = encrypted_file_key[NONCE_SIZE:]
    return crypto_aead_xchacha20poly1305_ietf_decrypt(
        ciphertext,
        b'securechat-file-key',
        nonce,
        session_key,
    )


def encrypt_metadata(metadata: Dict[str, Any], file_key: bytes) -> bytes:
    """
    Encrypt file metadata (filename, mime_type, size, dimensions, duration).
    Uses the same file_key so receiver can decrypt with a single key.
    """
    plaintext = json.dumps(metadata, separators=(',', ':')).encode('utf-8')
    nonce = os.urandom(NONCE_SIZE)
    ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(
        plaintext,
        b'securechat-file-meta',
        nonce,
        file_key,
    )
    return nonce + ciphertext


def decrypt_metadata(encrypted_metadata: bytes, file_key: bytes) -> Dict[str, Any]:
    """Decrypt file metadata."""
    nonce = encrypted_metadata[:NONCE_SIZE]
    ciphertext = encrypted_metadata[NONCE_SIZE:]
    plaintext = crypto_aead_xchacha20poly1305_ietf_decrypt(
        ciphertext,
        b'securechat-file-meta',
        nonce,
        file_key,
    )
    return json.loads(plaintext.decode('utf-8'))


def compute_file_hash(data: bytes) -> str:
    """SHA-256 hash of file data for integrity verification."""
    return hashlib.sha256(data).hexdigest()
