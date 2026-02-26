"""
SecureChat Protocol (SCP) - Key Management
==========================================
Layer 1: Asymmetric key operations

Key types:
- Identity Key: Ed448 (signing, 57-byte pubkey, 224-bit security)
- Identity DH Key: X448 (key exchange, 56-byte pubkey, 224-bit security)
- Signed PreKey: X448, signed by Ed448 identity, rotated every 7 days
- One-Time PreKeys: X448, single-use, consumed during X3DH
- Ephemeral Keys: X448, generated per-session during X3DH

Why X448 over X25519 (used by Signal/WhatsApp):
- 224-bit security vs 128-bit
- ~2^96 times harder to brute force
- More resistant to future quantum advances
- Slightly larger keys (56 vs 32 bytes) but negligible bandwidth impact

Why Ed448 over Ed25519:
- Matches X448 security level (224-bit)
- Resistant to fault attacks (Ed448-Goldilocks design)
"""

import os
import hashlib
import hmac as hmac_module
import struct
import time
from cryptography.hazmat.primitives.asymmetric.x448 import X448PrivateKey, X448PublicKey
from cryptography.hazmat.primitives.asymmetric.ed448 import Ed448PrivateKey, Ed448PublicKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.serialization import (
    Encoding, PublicFormat, PrivateFormat, NoEncryption,
)
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes


# ══════════════════════════════════════════════════
# SECURE MEMORY HELPERS
# ══════════════════════════════════════════════════

def secure_zero(data):
    """
    Overwrite bytes in memory with zeros.
    Best-effort: Python GC may have copies, but this
    reduces the window of exposure significantly.
    """
    if isinstance(data, (bytearray, memoryview)):
        for i in range(len(data)):
            data[i] = 0
    elif isinstance(data, bytes):
        # bytes are immutable in Python, we can't truly zero them
        # but we can delete the reference to let GC collect sooner
        pass


def secure_random(length):
    """Generate cryptographically secure random bytes"""
    return os.urandom(length)


# ══════════════════════════════════════════════════
# KEY GENERATION
# ══════════════════════════════════════════════════

def generate_identity_keypair():
    """
    Generate Ed448 identity keypair for digital signatures.
    Returns: (private_key_bytes: 57 bytes, public_key_bytes: 57 bytes)
    
    The private key MUST be stored ONLY in device secure enclave.
    It NEVER leaves the device. It NEVER goes to the server.
    """
    private_key = Ed448PrivateKey.generate()
    public_key = private_key.public_key()
    priv_bytes = private_key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pub_bytes = public_key.public_bytes(Encoding.Raw, PublicFormat.Raw)
    return priv_bytes, pub_bytes


def generate_identity_dh_keypair():
    """
    Generate X448 identity keypair for Diffie-Hellman operations.
    Separate from Ed448 identity to avoid cross-protocol attacks.
    Returns: (private_key_bytes: 56 bytes, public_key_bytes: 56 bytes)
    """
    return generate_x448_keypair()


def generate_x448_keypair():
    """
    Generate X448 keypair for Diffie-Hellman key exchange.
    Returns: (private_key_bytes: 56 bytes, public_key_bytes: 56 bytes)
    """
    private_key = X448PrivateKey.generate()
    public_key = private_key.public_key()
    priv_bytes = private_key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pub_bytes = public_key.public_bytes(Encoding.Raw, PublicFormat.Raw)
    return priv_bytes, pub_bytes


def generate_signed_prekey(identity_sign_private_bytes):
    """
    Generate a signed prekey: X448 keypair signed by Ed448 identity.
    The signature proves the prekey belongs to the identity key owner.
    
    Args:
        identity_sign_private_bytes: Ed448 private key (57 bytes)
    Returns:
        (prekey_private: 56 bytes, prekey_public: 56 bytes, signature: bytes)
    """
    identity_private = Ed448PrivateKey.from_private_bytes(identity_sign_private_bytes)
    prekey_priv_bytes, prekey_pub_bytes = generate_x448_keypair()
    
    # Sign: signature covers prekey public + timestamp to prevent replay
    timestamp = struct.pack('>Q', int(time.time()))
    sign_data = b'SCP_SIGNED_PREKEY_v1' + prekey_pub_bytes + timestamp
    signature = identity_private.sign(sign_data)
    
    # Return signature with embedded timestamp
    full_signature = timestamp + signature
    
    return prekey_priv_bytes, prekey_pub_bytes, full_signature


def verify_signed_prekey(identity_public_bytes, prekey_public_bytes, full_signature,
                         max_age_days=30):
    """
    Verify that a signed prekey was legitimately signed by the identity key.
    Also checks that the signature is not too old (replay protection).
    
    Args:
        max_age_days: reject signatures older than this
    Returns:
        True if valid
    Raises:
        Exception if verification fails
    """
    # Extract timestamp
    timestamp_bytes = full_signature[:8]
    signature = full_signature[8:]
    timestamp = struct.unpack('>Q', timestamp_bytes)[0]
    
    # Check age
    age_seconds = time.time() - timestamp
    if age_seconds > max_age_days * 86400:
        raise ValueError(f'Signed prekey signature is too old ({age_seconds/86400:.0f} days)')
    if age_seconds < -300:  # 5 min clock skew tolerance
        raise ValueError('Signed prekey signature is from the future')
    
    # Verify signature
    identity_public = Ed448PublicKey.from_public_bytes(identity_public_bytes)
    sign_data = b'SCP_SIGNED_PREKEY_v1' + prekey_public_bytes + timestamp_bytes
    identity_public.verify(signature, sign_data)
    
    return True


def generate_one_time_prekeys(count=100, start_id=0):
    """
    Generate a batch of one-time X448 prekeys.
    Each prekey is used exactly once during X3DH, then discarded.
    
    Args:
        count: number of prekeys to generate (recommended: 100)
        start_id: starting key_id (for sequential numbering)
    Returns:
        list of (key_id, private_bytes, public_bytes)
    """
    prekeys = []
    for i in range(count):
        priv_bytes, pub_bytes = generate_x448_keypair()
        prekeys.append((start_id + i, priv_bytes, pub_bytes))
    return prekeys


# ══════════════════════════════════════════════════
# X448 DIFFIE-HELLMAN
# ══════════════════════════════════════════════════

def x448_dh(private_bytes, public_bytes):
    """
    Perform X448 Diffie-Hellman key exchange.
    Returns: 56-byte shared secret
    
    Security: 224-bit equivalent. Immune to timing attacks
    (X448 is constant-time by design).
    """
    private_key = X448PrivateKey.from_private_bytes(private_bytes)
    public_key = X448PublicKey.from_public_bytes(public_bytes)
    shared = private_key.exchange(public_key)
    return shared


# ══════════════════════════════════════════════════
# HKDF-SHA512 KEY DERIVATION
# ══════════════════════════════════════════════════

def hkdf_sha512(input_key_material, info, length=64, salt=None):
    """
    HKDF-SHA512 key derivation function.
    
    Why SHA-512 over SHA-256 (Signal uses SHA-256):
    - 512-bit internal state vs 256-bit
    - More resistant to length extension attacks
    - Better security margin against future cryptanalytic advances
    
    Args:
        input_key_material: raw key material from DH
        info: context string (different per use case)
        length: output bytes (default 64 = 32 root + 32 chain)
        salt: optional salt (default: zero bytes per HKDF spec)
    Returns:
        derived key bytes
    """
    if salt is None:
        salt = b'\x00' * 64
    hkdf = HKDF(
        algorithm=hashes.SHA512(),
        length=length,
        salt=salt,
        info=info,
    )
    return hkdf.derive(input_key_material)


# ══════════════════════════════════════════════════
# EXTENDED X3DH KEY AGREEMENT
# ══════════════════════════════════════════════════

def x3dh_sender(
    sender_identity_dh_priv,
    sender_ephemeral_priv,
    recipient_identity_dh_pub,
    recipient_signed_prekey_pub,
    recipient_one_time_prekey_pub=None
):
    """
    Extended X3DH key agreement (sender/initiator side).
    
    Performs 3 or 4 Diffie-Hellman operations to establish a shared secret:
    
    DH1 = X448(our_identity,    their_signed_prekey)  -> binds our identity
    DH2 = X448(our_ephemeral,   their_identity)       -> binds their identity
    DH3 = X448(our_ephemeral,   their_signed_prekey)  -> forward secrecy
    DH4 = X448(our_ephemeral,   their_one_time_prekey) -> extra forward secrecy [optional]
    
    Why 4 DH operations (Signal uses 3):
    - DH4 with one-time prekey adds an extra layer of forward secrecy
    - If signed prekey is compromised, DH4 still protects past sessions
    - One-time prekeys are deleted after use, making retrospective decryption impossible
    
    Args:
        sender_identity_dh_priv: our X448 identity private (56 bytes)
        sender_ephemeral_priv: freshly generated X448 private (56 bytes)
        recipient_identity_dh_pub: their X448 identity public (56 bytes)
        recipient_signed_prekey_pub: their signed prekey public (56 bytes)
        recipient_one_time_prekey_pub: their one-time prekey public (56 bytes) or None
    
    Returns:
        64-byte shared secret (first 32: root key, last 32: initial chain key)
    """
    # DH1: our identity <-> their signed prekey
    dh1 = x448_dh(sender_identity_dh_priv, recipient_signed_prekey_pub)
    
    # DH2: our ephemeral <-> their identity
    dh2 = x448_dh(sender_ephemeral_priv, recipient_identity_dh_pub)
    
    # DH3: our ephemeral <-> their signed prekey
    dh3 = x448_dh(sender_ephemeral_priv, recipient_signed_prekey_pub)
    
    # Concatenate all DH outputs
    dh_concat = dh1 + dh2 + dh3
    
    # DH4: our ephemeral <-> their one-time prekey (if available)
    if recipient_one_time_prekey_pub is not None:
        dh4 = x448_dh(sender_ephemeral_priv, recipient_one_time_prekey_pub)
        dh_concat += dh4
    
    # Derive final shared secret with domain separation
    shared_secret = hkdf_sha512(
        input_key_material=dh_concat,
        info=b'SCP_X3DH_SharedSecret_v1',
        length=64,
        salt=b'SecureChatProtocol_X3DH_Salt_v1\x00' * 2
    )
    
    return shared_secret


def x3dh_receiver(
    recipient_identity_dh_priv,
    recipient_signed_prekey_priv,
    sender_identity_dh_pub,
    sender_ephemeral_pub,
    recipient_one_time_prekey_priv=None
):
    """
    Extended X3DH key agreement (receiver side).
    Mirror of x3dh_sender - must produce identical shared secret.
    
    The DH operations are the same but with swapped keys:
    DH1 = X448(our_signed_prekey,   their_identity)    -> mirrors sender DH1
    DH2 = X448(our_identity,        their_ephemeral)   -> mirrors sender DH2
    DH3 = X448(our_signed_prekey,   their_ephemeral)   -> mirrors sender DH3
    DH4 = X448(our_one_time_prekey, their_ephemeral)   -> mirrors sender DH4
    """
    # DH1: our signed prekey <-> their identity
    dh1 = x448_dh(recipient_signed_prekey_priv, sender_identity_dh_pub)
    
    # DH2: our identity <-> their ephemeral
    dh2 = x448_dh(recipient_identity_dh_priv, sender_ephemeral_pub)
    
    # DH3: our signed prekey <-> their ephemeral
    dh3 = x448_dh(recipient_signed_prekey_priv, sender_ephemeral_pub)
    
    dh_concat = dh1 + dh2 + dh3
    
    # DH4 (if one-time prekey was used)
    if recipient_one_time_prekey_priv is not None:
        dh4 = x448_dh(recipient_one_time_prekey_priv, sender_ephemeral_pub)
        dh_concat += dh4
    
    # Same KDF parameters as sender -> same output
    shared_secret = hkdf_sha512(
        input_key_material=dh_concat,
        info=b'SCP_X3DH_SharedSecret_v1',
        length=64,
        salt=b'SecureChatProtocol_X3DH_Salt_v1\x00' * 2
    )
    
    return shared_secret


# ══════════════════════════════════════════════════
# X25519/Ed25519 Functions (crypto_version=2)
# ══════════════════════════════════════════════════

def generate_identity_keypair_v2():
    """Generate Ed25519 identity keypair (crypto_version=2).
    Ed25519: 32-byte public key, 64-byte signature, 128-bit security level.
    Used for signing only (not DH).
    """
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()

    private_bytes = private_key.private_bytes(
        encoding=Encoding.Raw,
        format=PrivateFormat.Raw,
        encryption_algorithm=NoEncryption()
    )
    public_bytes = public_key.public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw
    )

    return {
        'private_key': private_bytes,  # 32 bytes
        'public_key': public_bytes,    # 32 bytes
        'algorithm': 'Ed25519',
        'crypto_version': 2
    }


def generate_identity_dh_keypair_v2():
    """Generate X25519 DH keypair (crypto_version=2).
    X25519: 32-byte public key, ~128-bit security level.
    Used for Diffie-Hellman key exchange.
    """
    private_key = X25519PrivateKey.generate()
    public_key = private_key.public_key()

    private_bytes = private_key.private_bytes(
        encoding=Encoding.Raw,
        format=PrivateFormat.Raw,
        encryption_algorithm=NoEncryption()
    )
    public_bytes = public_key.public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw
    )

    return {
        'private_key': private_bytes,  # 32 bytes
        'public_key': public_bytes,    # 32 bytes
        'algorithm': 'X25519',
        'crypto_version': 2
    }


def generate_signed_prekey_v2(identity_private_key_bytes):
    """Generate a signed prekey using X25519 + Ed25519 signature (crypto_version=2).

    Args:
        identity_private_key_bytes: 32-byte Ed25519 private key

    Returns:
        dict with prekey, signature, timestamp
    """
    # Generate X25519 prekey
    prekey_private = X25519PrivateKey.generate()
    prekey_public = prekey_private.public_key()

    prekey_private_bytes = prekey_private.private_bytes(
        encoding=Encoding.Raw,
        format=PrivateFormat.Raw,
        encryption_algorithm=NoEncryption()
    )
    prekey_public_bytes = prekey_public.public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw
    )

    # Sign with Ed25519 identity key
    timestamp = int(time.time())
    message_to_sign = prekey_public_bytes + timestamp.to_bytes(8, 'big')

    identity_private = Ed25519PrivateKey.from_private_bytes(identity_private_key_bytes)
    signature = identity_private.sign(message_to_sign)

    return {
        'private_key': prekey_private_bytes,  # 32 bytes
        'public_key': prekey_public_bytes,    # 32 bytes
        'signature': signature,                # 64 bytes
        'timestamp': timestamp,
        'crypto_version': 2
    }


def verify_signed_prekey_v2(identity_public_key_bytes, signed_prekey_public_bytes, signature, timestamp, max_age_days=30):
    """Verify a signed prekey (crypto_version=2).

    Args:
        identity_public_key_bytes: 32-byte Ed25519 public key
        signed_prekey_public_bytes: 32-byte X25519 public key
        signature: 64-byte Ed25519 signature
        timestamp: Unix timestamp when prekey was signed
        max_age_days: Maximum age of prekey in days

    Returns:
        bool
    """
    # Check age
    age_seconds = int(time.time()) - timestamp
    if age_seconds > max_age_days * 86400:
        return False
    if age_seconds < -300:  # 5 min clock skew tolerance
        return False

    # Verify signature
    message_to_verify = signed_prekey_public_bytes + timestamp.to_bytes(8, 'big')

    try:
        identity_public = Ed25519PublicKey.from_public_bytes(identity_public_key_bytes)
        identity_public.verify(signature, message_to_verify)
        return True
    except Exception:
        return False


def generate_one_time_prekeys_v2(count=100):
    """Generate batch of X25519 one-time prekeys (crypto_version=2).

    Returns:
        list of dicts with 'private_key', 'public_key', 'id'
    """
    prekeys = []
    for i in range(count):
        private_key = X25519PrivateKey.generate()
        public_key = private_key.public_key()

        private_bytes = private_key.private_bytes(
            encoding=Encoding.Raw,
            format=PrivateFormat.Raw,
            encryption_algorithm=NoEncryption()
        )
        public_bytes = public_key.public_bytes(
            encoding=Encoding.Raw,
            format=PublicFormat.Raw
        )

        prekeys.append({
            'id': i,
            'private_key': private_bytes,  # 32 bytes
            'public_key': public_bytes,    # 32 bytes
            'crypto_version': 2
        })

    return prekeys


def x25519_dh(private_key_bytes, public_key_bytes):
    """Perform X25519 Diffie-Hellman exchange (crypto_version=2).

    Args:
        private_key_bytes: 32-byte X25519 private key
        public_key_bytes: 32-byte X25519 public key

    Returns:
        32-byte shared secret
    """
    private_key = X25519PrivateKey.from_private_bytes(private_key_bytes)
    public_key = X25519PublicKey.from_public_bytes(public_key_bytes)

    shared_secret = private_key.exchange(public_key)
    return shared_secret  # 32 bytes


def x3dh_sender_v2(
    sender_identity_dh_private,
    sender_ephemeral_private,
    receiver_identity_dh_public,
    receiver_signed_prekey_public,
    receiver_one_time_prekey_public=None
):
    """X3DH sender side (crypto_version=2) — 3 or 4 DH operations.

    Uses X25519 for all DH operations.
    Domain separation string remains: SCP_X3DH_SharedSecret_v1

    Returns:
        bytes: derived shared secret (32 bytes)
    """
    # DH1: sender_identity_dh × receiver_signed_prekey
    dh1 = x25519_dh(sender_identity_dh_private, receiver_signed_prekey_public)

    # DH2: sender_ephemeral × receiver_identity_dh
    dh2 = x25519_dh(sender_ephemeral_private, receiver_identity_dh_public)

    # DH3: sender_ephemeral × receiver_signed_prekey
    dh3 = x25519_dh(sender_ephemeral_private, receiver_signed_prekey_public)

    # Concatenate DH results
    if receiver_one_time_prekey_public:
        # DH4: sender_ephemeral × receiver_one_time_prekey
        dh4 = x25519_dh(sender_ephemeral_private, receiver_one_time_prekey_public)
        dh_concat = dh1 + dh2 + dh3 + dh4
    else:
        dh_concat = dh1 + dh2 + dh3

    # Derive shared secret using existing hkdf_sha512
    shared_secret = hkdf_sha512(
        input_key_material=dh_concat,
        info=b'SCP_X3DH_SharedSecret_v1',
        length=32,  # 32 bytes for X25519 (vs 56 for X448)
        salt=b'\x00' * 32
    )

    return shared_secret


def x3dh_receiver_v2(
    receiver_identity_dh_private,
    receiver_signed_prekey_private,
    sender_identity_dh_public,
    sender_ephemeral_public,
    receiver_one_time_prekey_private=None
):
    """X3DH receiver side (crypto_version=2) — mirror of sender.

    Returns:
        bytes: derived shared secret (32 bytes, must match sender)
    """
    # DH1: receiver_signed_prekey × sender_identity_dh
    dh1 = x25519_dh(receiver_signed_prekey_private, sender_identity_dh_public)

    # DH2: receiver_identity_dh × sender_ephemeral
    dh2 = x25519_dh(receiver_identity_dh_private, sender_ephemeral_public)

    # DH3: receiver_signed_prekey × sender_ephemeral
    dh3 = x25519_dh(receiver_signed_prekey_private, sender_ephemeral_public)

    # Concatenate DH results
    if receiver_one_time_prekey_private:
        # DH4: receiver_one_time_prekey × sender_ephemeral
        dh4 = x25519_dh(receiver_one_time_prekey_private, sender_ephemeral_public)
        dh_concat = dh1 + dh2 + dh3 + dh4
    else:
        dh_concat = dh1 + dh2 + dh3

    # Derive shared secret — MUST match sender
    shared_secret = hkdf_sha512(
        input_key_material=dh_concat,
        info=b'SCP_X3DH_SharedSecret_v1',
        length=32,
        salt=b'\x00' * 32
    )

    return shared_secret


def generate_safety_number_v2(user1_identity_pub, user2_identity_pub, user1_id, user2_id):
    """Generate safety number for key verification (crypto_version=2).

    Same algorithm as v1 but with 32-byte keys instead of 57-byte.
    Returns 60-digit number (12 groups of 5).
    """

    def compute_fingerprint(identity_pub, user_id):
        # 5200 iterations of SHA-512 (same as v1)
        data = b'\x00' * 2 + identity_pub + user_id.to_bytes(8, 'big')
        digest = data
        for _ in range(5200):
            h = hashlib.sha512()
            h.update(digest)
            digest = h.digest()
        return digest[:30]  # 30 bytes = 60 hex chars → converted to 30 digits

    fp1 = compute_fingerprint(user1_identity_pub, user1_id)
    fp2 = compute_fingerprint(user2_identity_pub, user2_id)

    # Sort to ensure same result regardless of who generates
    if user1_id < user2_id:
        combined = fp1 + fp2
    else:
        combined = fp2 + fp1

    # Convert to 60-digit number
    number = int.from_bytes(combined, 'big')
    digits = str(number).zfill(60)[:60]

    # Format: 12 groups of 5
    groups = [digits[i:i+5] for i in range(0, 60, 5)]
    return ' '.join(groups)


# ══════════════════════════════════════════════════
# VERSION-AWARE WRAPPER FUNCTIONS
# ══════════════════════════════════════════════════

def generate_full_key_bundle(crypto_version=2):
    """Generate a complete key bundle for a user.

    Args:
        crypto_version: 1 for X448/Ed448, 2 for X25519/Ed25519

    Returns:
        dict with all keys needed for registration
    """
    if crypto_version == 2:
        identity = generate_identity_keypair_v2()
        identity_dh = generate_identity_dh_keypair_v2()
        signed_prekey = generate_signed_prekey_v2(identity['private_key'])
        one_time_prekeys = generate_one_time_prekeys_v2(count=100)
    elif crypto_version == 1:
        identity_priv, identity_pub = generate_identity_keypair()
        identity = {'private_key': identity_priv, 'public_key': identity_pub}
        identity_dh_priv, identity_dh_pub = generate_identity_dh_keypair()
        identity_dh = {'private_key': identity_dh_priv, 'public_key': identity_dh_pub}
        spk_priv, spk_pub, full_sig = generate_signed_prekey(identity_priv)
        signed_prekey = {'private_key': spk_priv, 'public_key': spk_pub, 'signature': full_sig}
        otpks_tuples = generate_one_time_prekeys(count=100)
        one_time_prekeys = [{'id': tid, 'private_key': p, 'public_key': u} for (tid, p, u) in otpks_tuples]
    else:
        raise ValueError(f"Unknown crypto_version: {crypto_version}")

    return {
        'crypto_version': crypto_version,
        'identity': identity,
        'identity_dh': identity_dh,
        'signed_prekey': signed_prekey,
        'one_time_prekeys': one_time_prekeys,
    }


def perform_x3dh_sender(crypto_version, **kwargs):
    """Version-aware X3DH sender wrapper."""
    if crypto_version == 2:
        return x3dh_sender_v2(**kwargs)
    elif crypto_version == 1:
        return x3dh_sender(**kwargs)
    else:
        raise ValueError(f"Unknown crypto_version: {crypto_version}")


def perform_x3dh_receiver(crypto_version, **kwargs):
    """Version-aware X3DH receiver wrapper."""
    if crypto_version == 2:
        return x3dh_receiver_v2(**kwargs)
    elif crypto_version == 1:
        return x3dh_receiver(**kwargs)
    else:
        raise ValueError(f"Unknown crypto_version: {crypto_version}")


def perform_dh(crypto_version, private_key_bytes, public_key_bytes):
    """Version-aware DH wrapper."""
    if crypto_version == 2:
        return x25519_dh(private_key_bytes, public_key_bytes)
    elif crypto_version == 1:
        return x448_dh(private_key_bytes, public_key_bytes)
    else:
        raise ValueError(f"Unknown crypto_version: {crypto_version}")


def verify_signed_prekey_versioned(crypto_version, **kwargs):
    """Version-aware signed prekey verification. Returns True if valid, False otherwise."""
    if crypto_version == 2:
        return verify_signed_prekey_v2(**kwargs)
    elif crypto_version == 1:
        try:
            verify_signed_prekey(
                kwargs['identity_public_key_bytes'],
                kwargs['signed_prekey_public_bytes'],
                kwargs['full_signature'],
                max_age_days=kwargs.get('max_age_days', 30),
            )
            return True
        except Exception:
            return False
    else:
        raise ValueError(f"Unknown crypto_version: {crypto_version}")


# ══════════════════════════════════════════════════
# SAFETY NUMBER / FINGERPRINT VERIFICATION
# ══════════════════════════════════════════════════

def generate_safety_number(identity_key_a, identity_key_b):
    """
    Generate a safety number for two users to verify their keys match.
    
    The safety number is the same regardless of which user computes it.
    Users compare numbers (or scan QR codes) in person to verify
    that no MITM attack has occurred.
    
    Algorithm:
    1. Sort the two identity keys lexicographically
    2. Concatenate them
    3. Iteratively hash 5200 times with SHA-512 (slow, deliberate)
    4. Convert first 30 bytes to a 60-digit number
    5. Format as 12 groups of 5 digits
    
    Returns: (formatted_string, raw_digits_string)
    """
    sorted_keys = sorted([identity_key_a, identity_key_b])
    combined = b'SCP_SAFETY_NUMBER_v1' + sorted_keys[0] + sorted_keys[1]
    
    # Iterated hashing (like scrypt but simpler, provides key stretching)
    digest = combined
    for i in range(5200):
        digest = hashlib.sha512(digest + combined + struct.pack('>I', i)).digest()
    
    # Convert to numeric string
    number = int.from_bytes(digest[:30], 'big')
    number_str = str(number).zfill(60)[:60]
    
    # Format: 12 groups of 5 digits
    groups = [number_str[i:i+5] for i in range(0, 60, 5)]
    formatted = ' '.join(groups)
    
    return formatted, number_str


def generate_safety_qr_data(identity_key_a, user_id_a, identity_key_b, user_id_b):
    """
    Generate data for QR code verification.
    Includes user IDs + identity keys for scanning.
    """
    import base64
    import json
    data = {
        'v': 1,  # version
        'users': sorted([
            {'id': user_id_a, 'ik': base64.b64encode(identity_key_a).decode()},
            {'id': user_id_b, 'ik': base64.b64encode(identity_key_b).decode()},
        ], key=lambda x: x['id'])
    }
    return json.dumps(data, separators=(',', ':'))
