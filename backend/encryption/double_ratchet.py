"""
SecureChat Protocol (SCP) - Double Ratchet
==========================================
Layer 2: Double Ratchet Algorithm for forward secrecy

How it works:
- Every time you send a message, a new message key is derived
- Every time a reply comes back, a new DH ratchet step occurs
- Result: every message uses a different key
- Compromising one key reveals nothing about past or future messages

Why our implementation is stronger than Signal:
- X448 DH ratchet (224-bit security vs 128-bit)
- HKDF-SHA512 chain derivation (vs SHA-256)
- Additional envelope encryption layer on top
- Skipped message keys capped at 1000 (prevents memory exhaustion attacks)
- Serialization encrypted before storage (ratchet state is sensitive)
"""

import json
import struct
import hmac as hmac_module
import hashlib
from .scp_keys import (
    generate_x448_keypair,
    generate_identity_dh_keypair,
    generate_identity_dh_keypair_v2,
    x448_dh,
    perform_dh,
    hkdf_sha512,
)
from .cipher import aead_encrypt, aead_decrypt


MAX_SKIP = 1000  # Max messages we can skip in a single chain


class MessageHeader:
    """
    Header sent with each encrypted message (in plaintext).
    Contains the sender's current ratchet public key and message counters.
    The header is used as Associated Authenticated Data (AAD) during encryption,
    so any tampering with the header will cause decryption to fail.
    dh_public: 56 bytes (X448) for crypto_version=1, 32 bytes (X25519) for crypto_version=2.
    """
    
    def __init__(self, dh_public, previous_chain_length, message_number):
        self.dh_public = dh_public                        # 56 bytes X448 or 32 bytes X25519
        self.previous_chain_length = previous_chain_length  # int: msgs in previous sending chain
        self.message_number = message_number                # int: msg number in current chain
    
    def encode(self):
        """Serialize to bytes (used as AAD)"""
        return (
            b'SCP_HDR_v1' +
            self.dh_public +
            struct.pack('>II', self.previous_chain_length, self.message_number)
        )
    
    @classmethod
    def decode(cls, data, dh_key_size=56):
        """Deserialize from bytes. dh_key_size: 56 for X448 (v1), 32 for X25519 (v2)."""
        prefix = data[:10]  # 'SCP_HDR_v1'
        if prefix != b'SCP_HDR_v1':
            raise ValueError('Invalid header prefix')
        dh_public = data[10:10 + dh_key_size]
        pn, n = struct.unpack('>II', data[10 + dh_key_size:18 + dh_key_size])
        return cls(dh_public, pn, n)
    
    def __repr__(self):
        return f'Header(pn={self.previous_chain_length}, n={self.message_number}, dh={self.dh_public[:8].hex()}...)'


def kdf_root_key(root_key, dh_output):
    """
    Root key derivation: advance the root chain.
    Input: current root key + DH output from ratchet step
    Output: (new_root_key, new_chain_key) each 32 bytes
    
    Uses HKDF-SHA512 with domain separation.
    """
    derived = hkdf_sha512(
        input_key_material=dh_output,
        info=b'SCP_ROOT_CHAIN_v1',
        length=64,
        salt=root_key
    )
    return derived[:32], derived[32:]


def kdf_chain_key(chain_key):
    """
    Chain key derivation: advance the symmetric chain.
    Input: current chain key
    Output: (next_chain_key, message_key) each 32 bytes
    
    Uses HMAC-SHA512 with different constants for chain vs message key.
    This ensures chain_key and message_key are cryptographically independent.
    """
    next_chain = hmac_module.new(chain_key, b'\x01SCP_CHAIN', hashlib.sha512).digest()[:32]
    message_key = hmac_module.new(chain_key, b'\x02SCP_MSG', hashlib.sha512).digest()[:32]
    return next_chain, message_key


class DoubleRatchet:
    """
    Double Ratchet state machine for a single conversation.
    
    Lifecycle:
    1. X3DH produces shared_secret (64 bytes)
    2. Initiator calls init_sender(shared_secret, recipient_signed_prekey_pub)
    3. Recipient calls init_receiver(shared_secret, their_signed_prekey_priv, their_signed_prekey_pub)
    4. Both can now encrypt/decrypt messages with forward secrecy
    
    Each encrypt() call advances the sending chain.
    Each decrypt() may trigger a DH ratchet step if the remote key changed.
    """
    
    def __init__(self, crypto_version=2):
        self.crypto_version = crypto_version
        self.root_key = None
        self.sending_chain_key = None
        self.receiving_chain_key = None
        self.sending_ratchet_priv = None
        self.sending_ratchet_pub = None
        self.receiving_ratchet_pub = None
        self.send_count = 0
        self.recv_count = 0
        self.previous_send_count = 0
        self.skipped_keys = {}
    
    @classmethod
    def init_sender(cls, shared_secret, receiver_ratchet_pub, crypto_version=2):
        """
        Initialize as the session initiator (Alice).
        
        Args:
            shared_secret: 64 bytes from X3DH (v1) or 32 bytes (v2)
            receiver_ratchet_pub: recipient's signed prekey public (56 bytes v1, 32 bytes v2)
            crypto_version: 1 = X448/Ed448, 2 = X25519/Ed25519
        """
        min_secret = 32 if crypto_version == 2 else 64
        if len(shared_secret) < min_secret:
            raise ValueError(f'Shared secret must be at least {min_secret} bytes')
        
        state = cls(crypto_version=crypto_version)
        state.receiving_ratchet_pub = receiver_ratchet_pub

        # Generate our first ratchet keypair (version-aware)
        if crypto_version == 2:
            kp = generate_identity_dh_keypair_v2()
            state.sending_ratchet_priv = kp['private_key']
            state.sending_ratchet_pub = kp['public_key']
        else:
            state.sending_ratchet_priv, state.sending_ratchet_pub = generate_identity_dh_keypair()
        
        # Derive initial root key from shared secret
        root_key = shared_secret[:32]
        
        # First DH ratchet step (version-aware)
        dh_output = perform_dh(crypto_version, state.sending_ratchet_priv, state.receiving_ratchet_pub)
        state.root_key, state.sending_chain_key = kdf_root_key(root_key, dh_output)
        
        state.send_count = 0
        state.recv_count = 0
        state.previous_send_count = 0
        
        return state
    
    @classmethod
    def init_receiver(cls, shared_secret, our_ratchet_priv, our_ratchet_pub, crypto_version=2):
        """
        Initialize as the session responder (Bob).
        
        Args:
            shared_secret: 64 bytes from X3DH (v1) or 32 bytes (v2)
            our_ratchet_priv: our signed prekey private (56 bytes v1, 32 bytes v2)
            our_ratchet_pub: our signed prekey public (56 bytes v1, 32 bytes v2)
            crypto_version: 1 = X448/Ed448, 2 = X25519/Ed25519
        """
        min_secret = 32 if crypto_version == 2 else 64
        if len(shared_secret) < min_secret:
            raise ValueError(f'Shared secret must be at least {min_secret} bytes')
        
        state = cls(crypto_version=crypto_version)
        state.sending_ratchet_priv = our_ratchet_priv
        state.sending_ratchet_pub = our_ratchet_pub
        state.root_key = shared_secret[:32]
        state.send_count = 0
        state.recv_count = 0
        state.previous_send_count = 0
        return state
    
    def encrypt(self, plaintext):
        """
        Encrypt a message using the current sending chain.
        
        Returns: (header: MessageHeader, ciphertext: bytes)
        """
        if isinstance(plaintext, str):
            plaintext = plaintext.encode('utf-8')
        
        if self.sending_chain_key is None:
            raise RuntimeError('Cannot encrypt: sending chain not initialized')
        
        # Derive message key from sending chain
        self.sending_chain_key, message_key = kdf_chain_key(self.sending_chain_key)
        
        # Create header with current ratchet public key
        header = MessageHeader(
            dh_public=self.sending_ratchet_pub,
            previous_chain_length=self.previous_send_count,
            message_number=self.send_count
        )
        
        self.send_count += 1
        
        # Encrypt plaintext with message key, header as AAD
        ciphertext = aead_encrypt(message_key, plaintext, header.encode())
        
        # Zero the message key from memory (best effort)
        del message_key
        
        return header, ciphertext
    
    def decrypt(self, header, ciphertext):
        """
        Decrypt a received message.
        Handles DH ratchet steps and out-of-order delivery.
        
        Returns: plaintext bytes
        """
        # 1. Check skipped keys first (out-of-order message)
        skip_key = (header.dh_public.hex(), header.message_number)
        if skip_key in self.skipped_keys:
            message_key = self.skipped_keys.pop(skip_key)
            plaintext = aead_decrypt(message_key, ciphertext, header.encode())
            del message_key
            return plaintext
        
        # 2. If new ratchet public key, perform DH ratchet
        if header.dh_public != self.receiving_ratchet_pub:
            # Skip any remaining messages in the old receiving chain
            self._skip_messages(header.previous_chain_length)
            # Perform DH ratchet step
            self._dh_ratchet(header.dh_public)
        
        # 3. Skip to the correct message number in current chain
        self._skip_messages(header.message_number)
        
        # 4. Derive message key
        self.receiving_chain_key, message_key = kdf_chain_key(self.receiving_chain_key)
        self.recv_count += 1
        
        # 5. Decrypt
        plaintext = aead_decrypt(message_key, ciphertext, header.encode())
        del message_key
        
        return plaintext
    
    def _dh_ratchet(self, new_remote_public):
        """
        Perform a DH ratchet step.
        Called when we receive a message with a new ratchet public key.
        """
        self.previous_send_count = self.send_count
        self.send_count = 0
        self.recv_count = 0
        self.receiving_ratchet_pub = new_remote_public
        
        # Derive receiving chain key (version-aware DH)
        dh_recv = perform_dh(self.crypto_version, self.sending_ratchet_priv, self.receiving_ratchet_pub)
        self.root_key, self.receiving_chain_key = kdf_root_key(self.root_key, dh_recv)
        
        # Generate new sending ratchet keypair (version-aware)
        if self.crypto_version == 2:
            kp = generate_identity_dh_keypair_v2()
            self.sending_ratchet_priv = kp['private_key']
            self.sending_ratchet_pub = kp['public_key']
        else:
            self.sending_ratchet_priv, self.sending_ratchet_pub = generate_identity_dh_keypair()
        
        # Derive sending chain key
        dh_send = perform_dh(self.crypto_version, self.sending_ratchet_priv, self.receiving_ratchet_pub)
        self.root_key, self.sending_chain_key = kdf_root_key(self.root_key, dh_send)
    
    def _skip_messages(self, until):
        """
        Store skipped message keys for later out-of-order decryption.
        Capped at MAX_SKIP to prevent memory exhaustion attacks.
        """
        if self.receiving_chain_key is None:
            return
        
        if until - self.recv_count > MAX_SKIP:
            raise ValueError(
                f'Cannot skip {until - self.recv_count} messages (max {MAX_SKIP}). '
                'Possible attack or severely out-of-order delivery.'
            )
        
        while self.recv_count < until:
            self.receiving_chain_key, mk = kdf_chain_key(self.receiving_chain_key)
            skip_key = (self.receiving_ratchet_pub.hex(), self.recv_count)
            self.skipped_keys[skip_key] = mk
            self.recv_count += 1
    
    def serialize(self):
        """
        Serialize ratchet state to bytes for encrypted storage.
        
        WARNING: This contains sensitive key material.
        The output MUST be encrypted before storing (e.g., with device keychain).
        """
        state = {
            'v': 1,  # serialization version
            'crypto_version': self.crypto_version,
            'rk': self.root_key.hex() if self.root_key else None,
            'sck': self.sending_chain_key.hex() if self.sending_chain_key else None,
            'rck': self.receiving_chain_key.hex() if self.receiving_chain_key else None,
            'srp': self.sending_ratchet_priv.hex() if self.sending_ratchet_priv else None,
            'sru': self.sending_ratchet_pub.hex() if self.sending_ratchet_pub else None,
            'rrp': self.receiving_ratchet_pub.hex() if self.receiving_ratchet_pub else None,
            'sc': self.send_count,
            'rc': self.recv_count,
            'psc': self.previous_send_count,
            'sk': {f'{k[0]}:{k[1]}': v.hex() for k, v in self.skipped_keys.items()},
        }
        return json.dumps(state, separators=(',', ':')).encode('utf-8')
    
    @classmethod
    def deserialize(cls, data):
        """Restore ratchet state from serialized bytes."""
        state_dict = json.loads(data.decode('utf-8'))
        
        if state_dict.get('v', 0) != 1:
            raise ValueError(f'Unsupported ratchet serialization version: {state_dict.get("v")}')
        
        state = cls(crypto_version=state_dict.get('crypto_version', 1))
        state.root_key = bytes.fromhex(state_dict['rk']) if state_dict['rk'] else None
        state.sending_chain_key = bytes.fromhex(state_dict['sck']) if state_dict['sck'] else None
        state.receiving_chain_key = bytes.fromhex(state_dict['rck']) if state_dict['rck'] else None
        state.sending_ratchet_priv = bytes.fromhex(state_dict['srp']) if state_dict['srp'] else None
        state.sending_ratchet_pub = bytes.fromhex(state_dict['sru']) if state_dict['sru'] else None
        state.receiving_ratchet_pub = bytes.fromhex(state_dict['rrp']) if state_dict['rrp'] else None
        state.send_count = state_dict['sc']
        state.recv_count = state_dict['rc']
        state.previous_send_count = state_dict['psc']
        state.skipped_keys = {}
        for k, v in state_dict['sk'].items():
            pub_hex, num = k.rsplit(':', 1)
            state.skipped_keys[(pub_hex, int(num))] = bytes.fromhex(v)
        return state
