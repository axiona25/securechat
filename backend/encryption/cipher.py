"""
SecureChat Protocol (SCP) - Symmetric Cipher
=============================================
Layer 3: XChaCha20-Poly1305 AEAD encryption (via libsodium/PyNaCl)
Layer 4: Envelope encryption (ephemeral key per message)

Why XChaCha20-Poly1305 (24-byte nonce) over ChaCha20-Poly1305 (12-byte nonce):
- 192-bit nonce vs 96-bit: collision probability negligible even after 2^96 encryptions
- With 12-byte nonce, after ~2^32 messages under same key, collision risk becomes real
- 24-byte nonce allows safe random nonce generation without counters
- libsodium's implementation is battle-tested and formally verified

Why over AES-256-GCM (used by WhatsApp):
- AES-GCM nonce reuse = catastrophic (full plaintext recovery + auth key leak)
- XChaCha20 nonce reuse = bad but not catastrophic (no auth key leak)
- No AES cache-timing side channels
- Constant-time on all hardware (no need for AES-NI)
"""

import os
import struct
import time
import hashlib
import nacl.secret
import nacl.utils


# ══════════════════════════════════════════════════
# CONSTANTS
# ══════════════════════════════════════════════════

NONCE_SIZE = 24        # XChaCha20 extended nonce (192 bits)
KEY_SIZE = 32          # 256-bit key
TAG_SIZE = 16          # Poly1305 authentication tag
CHUNK_SIZE = 65536     # 64KB chunks for large files
MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB max


# ══════════════════════════════════════════════════
# XCHACHA20-POLY1305 AEAD (via libsodium)
# ══════════════════════════════════════════════════

def aead_encrypt(key, plaintext, associated_data=b''):
    """
    Encrypt with XChaCha20-Poly1305 AEAD using libsodium via PyNaCl.
    
    Args:
        key: 32-byte encryption key
        plaintext: data to encrypt (bytes or str)
        associated_data: additional authenticated data (AAD)
    
    Returns:
        bytes: nonce (24) + ciphertext + auth_tag (16)
    
    The 24-byte nonce is randomly generated. With 192-bit nonces,
    collision probability after N messages is approximately N^2 / 2^192.
    Even after 2^80 messages (~10^24), collision chance is ~2^-32.
    """
    if len(key) != KEY_SIZE:
        raise ValueError(f'Key must be {KEY_SIZE} bytes, got {len(key)}')
    if isinstance(plaintext, str):
        plaintext = plaintext.encode('utf-8')
    if isinstance(associated_data, str):
        associated_data = associated_data.encode('utf-8')
    
    # Generate 24-byte random nonce (XChaCha20 extended nonce)
    nonce = nacl.utils.random(NONCE_SIZE)
    
    # Create SecretBox-like encryption with AAD
    # PyNaCl's SecretBox uses XSalsa20, but we use the lower-level
    # nacl.bindings for XChaCha20-Poly1305 with AAD
    try:
        from nacl.bindings import (
            crypto_aead_xchacha20poly1305_ietf_encrypt,
            crypto_aead_xchacha20poly1305_ietf_decrypt,
        )
        ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(
            plaintext, associated_data, nonce, key
        )
    except ImportError:
        # Fallback: use SecretBox (XSalsa20-Poly1305, also 24-byte nonce)
        # Less ideal but still 24-byte nonce and battle-tested
        box = nacl.secret.SecretBox(key)
        # SecretBox doesn't support AAD natively, so we hash AAD into the plaintext
        # Format: [32 bytes: SHA-256 of AAD] + [plaintext]
        aad_hash = hashlib.sha256(associated_data).digest()
        combined = aad_hash + plaintext
        encrypted = box.encrypt(combined, nonce)
        # encrypted = nonce + ciphertext (SecretBox prepends nonce)
        # We want our own format: nonce + ciphertext
        return nonce + encrypted.ciphertext
    
    return nonce + ciphertext


def aead_decrypt(key, data, associated_data=b''):
    """
    Decrypt XChaCha20-Poly1305 AEAD.
    
    Args:
        key: 32-byte key
        data: nonce (24) + ciphertext + tag
        associated_data: must match encryption AAD
    
    Returns:
        decrypted plaintext bytes
    
    Raises:
        nacl.exceptions.CryptoError: if authentication fails
    """
    if len(key) != KEY_SIZE:
        raise ValueError(f'Key must be {KEY_SIZE} bytes, got {len(key)}')
    if isinstance(associated_data, str):
        associated_data = associated_data.encode('utf-8')
    if len(data) < NONCE_SIZE + TAG_SIZE:
        raise ValueError('Data too short to contain nonce + tag')
    
    nonce = data[:NONCE_SIZE]
    ciphertext = data[NONCE_SIZE:]
    
    try:
        from nacl.bindings import (
            crypto_aead_xchacha20poly1305_ietf_encrypt,
            crypto_aead_xchacha20poly1305_ietf_decrypt,
        )
        plaintext = crypto_aead_xchacha20poly1305_ietf_decrypt(
            ciphertext, associated_data, nonce, key
        )
    except ImportError:
        # Fallback: SecretBox
        box = nacl.secret.SecretBox(key)
        combined = box.decrypt(ciphertext, nonce)
        # Verify AAD hash
        aad_hash = hashlib.sha256(associated_data).digest()
        if combined[:32] != aad_hash:
            raise ValueError('AAD verification failed')
        plaintext = combined[32:]
    
    return plaintext


# ══════════════════════════════════════════════════
# ENVELOPE ENCRYPTION (Layer 4)
# ══════════════════════════════════════════════════

def envelope_encrypt(plaintext, associated_data=b''):
    """
    Envelope encryption: unique ephemeral key per message.
    
    1. Generate random 256-bit ephemeral key
    2. Encrypt plaintext with ephemeral key
    3. Return ephemeral key separately (caller encrypts it with session key)
    
    Returns:
        (ephemeral_key: 32 bytes, encrypted_data: bytes)
        encrypted_data = timestamp (8 bytes) + nonce (24) + ciphertext + tag (16)
    """
    ephemeral_key = nacl.utils.random(KEY_SIZE)
    
    # Add timestamp to AAD for replay protection
    timestamp = struct.pack('>Q', int(time.time() * 1000))
    full_aad = b'SCP_ENVELOPE_v1' + timestamp + (associated_data if isinstance(associated_data, bytes) else associated_data.encode('utf-8'))
    
    encrypted_data = aead_encrypt(ephemeral_key, plaintext, full_aad)
    
    # Prepend timestamp so receiver can reconstruct AAD
    return ephemeral_key, timestamp + encrypted_data


def envelope_decrypt(ephemeral_key, encrypted_data_with_ts, associated_data=b'',
                     max_age_seconds=86400):
    """
    Decrypt envelope-encrypted data.
    Rejects messages older than max_age_seconds (anti-replay).
    """
    timestamp = encrypted_data_with_ts[:8]
    encrypted_data = encrypted_data_with_ts[8:]
    
    # Check age (anti-replay)
    msg_time_ms = struct.unpack('>Q', timestamp)[0]
    age_seconds = (time.time() * 1000 - msg_time_ms) / 1000
    if age_seconds > max_age_seconds:
        raise ValueError(f'Message too old ({age_seconds:.0f}s > {max_age_seconds}s)')
    if age_seconds < -300:  # 5 min clock skew tolerance
        raise ValueError('Message timestamp is in the future')
    
    full_aad = b'SCP_ENVELOPE_v1' + timestamp + (associated_data if isinstance(associated_data, bytes) else associated_data.encode('utf-8'))
    return aead_decrypt(ephemeral_key, encrypted_data, full_aad)


# ══════════════════════════════════════════════════
# MESSAGE WIRE FORMAT
# ══════════════════════════════════════════════════

SCP_MAGIC = b'SCP1'
SCP_VERSION = 1

def pack_message(header_bytes, encrypted_envelope_key, encrypted_payload):
    """
    Pack a complete SCP message for wire transmission.
    
    Format:
    [4B: magic 'SCP1'][1B: version][2B: header_len][header]
    [2B: eek_len][encrypted_envelope_key][remaining: encrypted_payload]
    """
    parts = [
        SCP_MAGIC,
        struct.pack('B', SCP_VERSION),
        struct.pack('>H', len(header_bytes)),
        header_bytes,
        struct.pack('>H', len(encrypted_envelope_key)),
        encrypted_envelope_key,
        encrypted_payload,
    ]
    return b''.join(parts)


def unpack_message(data):
    """
    Unpack a received SCP message.
    Returns: (version, header_bytes, encrypted_envelope_key, encrypted_payload)
    """
    if data[:4] != SCP_MAGIC:
        raise ValueError('Not an SCP message (invalid magic bytes)')
    
    version = struct.unpack('B', data[4:5])[0]
    if version != SCP_VERSION:
        raise ValueError(f'Unsupported SCP version: {version}')
    
    offset = 5
    header_len = struct.unpack('>H', data[offset:offset+2])[0]
    offset += 2
    header_bytes = data[offset:offset+header_len]
    offset += header_len
    
    eek_len = struct.unpack('>H', data[offset:offset+2])[0]
    offset += 2
    encrypted_envelope_key = data[offset:offset+eek_len]
    offset += eek_len
    
    encrypted_payload = data[offset:]
    
    return version, header_bytes, encrypted_envelope_key, encrypted_payload


# ══════════════════════════════════════════════════
# FILE/MEDIA ENCRYPTION
# ══════════════════════════════════════════════════

def encrypt_file(file_data, associated_data=b''):
    """
    Encrypt a file/media attachment with integrity verification.
    
    Small files (<=64KB): single AEAD encryption
    Large files: 64KB chunks, each with own nonce and chunk index in AAD
    SHA-256 hash of plaintext stored for post-decryption integrity check.
    
    Returns: (file_key: 32 bytes, encrypted_data: bytes)
    """
    if len(file_data) > MAX_FILE_SIZE:
        raise ValueError(f'File too large: {len(file_data)} bytes (max {MAX_FILE_SIZE})')
    
    file_key = nacl.utils.random(KEY_SIZE)
    file_hash = hashlib.sha256(file_data).digest()
    
    if len(file_data) <= CHUNK_SIZE:
        # Single encryption
        aad = b'SCP_FILE_SINGLE_v1' + file_hash + (associated_data if isinstance(associated_data, bytes) else b'')
        encrypted = aead_encrypt(file_key, file_data, aad)
        return file_key, b'\x00' + file_hash + encrypted
    else:
        # Chunked encryption
        chunks = []
        num_chunks = (len(file_data) + CHUNK_SIZE - 1) // CHUNK_SIZE
        
        for i in range(num_chunks):
            start = i * CHUNK_SIZE
            end = min(start + CHUNK_SIZE, len(file_data))
            chunk = file_data[start:end]
            
            chunk_aad = (b'SCP_FILE_CHUNK_v1' + file_hash +
                        struct.pack('>II', i, num_chunks) +
                        (associated_data if isinstance(associated_data, bytes) else b''))
            encrypted_chunk = aead_encrypt(file_key, chunk, chunk_aad)
            chunks.append(encrypted_chunk)
        
        parts = [b'\x01', file_hash, struct.pack('>I', num_chunks)]
        for ec in chunks:
            parts.append(struct.pack('>I', len(ec)))
            parts.append(ec)
        
        return file_key, b''.join(parts)


def decrypt_file(file_key, encrypted_file_data, associated_data=b''):
    """
    Decrypt a file and verify SHA-256 integrity.
    Raises ValueError if file was tampered with.
    """
    mode = encrypted_file_data[0]
    file_hash = encrypted_file_data[1:33]
    payload = encrypted_file_data[33:]
    
    if mode == 0:
        # Single file
        aad = b'SCP_FILE_SINGLE_v1' + file_hash + (associated_data if isinstance(associated_data, bytes) else b'')
        decrypted = aead_decrypt(file_key, payload, aad)
    elif mode == 1:
        # Chunked file
        num_chunks = struct.unpack('>I', payload[:4])[0]
        offset = 4
        decrypted_chunks = []
        
        for i in range(num_chunks):
            chunk_len = struct.unpack('>I', payload[offset:offset+4])[0]
            offset += 4
            chunk_data = payload[offset:offset+chunk_len]
            offset += chunk_len
            
            chunk_aad = (b'SCP_FILE_CHUNK_v1' + file_hash +
                        struct.pack('>II', i, num_chunks) +
                        (associated_data if isinstance(associated_data, bytes) else b''))
            decrypted_chunks.append(aead_decrypt(file_key, chunk_data, chunk_aad))
        
        decrypted = b''.join(decrypted_chunks)
    else:
        raise ValueError(f'Unknown file encryption mode: {mode}')
    
    # Verify integrity
    actual_hash = hashlib.sha256(decrypted).digest()
    if actual_hash != file_hash:
        raise ValueError('File integrity check failed! Data may have been tampered with.')
    
    return decrypted
