# Codice rilevante: flusso chiavi e KeyBundle (auth → crypto → session → backend)

Solo funzioni/metodi relativi a login, register, generazione KeyBundle, upload/fetch chiavi e inizializzazione sessioni X3DH.

---

## 1. lib/core/services/auth_service.dart

**Percorso:** `lib/core/services/auth_service.dart`

### `login()` — dopo autenticazione chiama l’inizializzazione delle chiavi

```dart
Future<AuthResult> login({
  required String email,
  required String password,
}) async {
  try {
    final data = await _api.post('/auth/login/', body: {
      'email': email,
      'password': password,
    });

    final access = data['access'] as String?;
    final refresh = data['refresh'] as String?;

    if (access != null && refresh != null) {
      _api.setTokens(access: access, refresh: refresh);
      final user = data['user'] as Map<String, dynamic>?;
      final userId = user?['id'];
      if (userId != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_keyCurrentUserId, userId is int ? userId : int.tryParse(userId.toString()) ?? 0);
      }
      // Initialize E2E encryption keys (idempotent; does not block login on failure)
      try {
        print('[Auth] Starting crypto key initialization...');
        final keysOk = await CryptoService(apiService: _api).initializeKeys();
        print('[Auth] Crypto init result: $keysOk');
      } catch (e, stack) {
        print('[Auth] Crypto init FAILED: $e');
        print('[Auth] Stack: $stack');
      }
      // ... FCM token registration ...
      return AuthResult(success: true, accessToken: access, refreshToken: refresh);
    }
    return AuthResult(success: false, error: 'Invalid response from server.');
  } on ApiException catch (e) { /* ... */ }
}
```

### `register()` — nessuna chiamata crypto

Il register effettua solo la POST a `/auth/register/` e restituisce `AuthResult(success: true)`. La generazione/upload delle chiavi avviene al primo **login** successivo tramite `CryptoService().initializeKeys()`.

```dart
Future<AuthResult> register({
  required String fullName,
  required String email,
  required String password,
  required String passwordConfirm,
}) async {
  try {
    // ... build username, firstName, lastName ...
    await _api.post('/auth/register/', body: {
      'username': username,
      'email': email,
      'password': password,
      'password_confirm': passwordConfirm,
      'first_name': firstName,
      'last_name': lastName,
    });
    return AuthResult(success: true);
  } on ApiException catch (e) { /* ... */ }
}
```

---

## 2. lib/core/services/crypto_service.dart

**Percorso:** `lib/core/services/crypto_service.dart`

### Generazione KeyBundle (identity key, signed prekey, one-time prekeys)

```dart
/// Generate complete key bundle and store private keys securely.
/// Call this once at registration or first login.
Future<Map<String, dynamic>> generateAndStoreKeyBundle() async {
  debugPrint('[CryptoService] generateAndStoreKeyBundle START');
  // 1. Generate Ed25519 identity keypair (for signing)
  final signingKey = SigningKey.generate();
  final identityPrivate = Uint8List.fromList(signingKey.seed.asTypedList);
  final identityPublic = Uint8List.fromList(signingKey.verifyKey.asTypedList);

  // 2. Generate X25519 identity DH keypair (for key exchange)
  final identityDhKey = PrivateKey.generate();
  final identityDhPublic = identityDhKey.publicKey;

  // 3. Generate X25519 signed prekey
  final signedPreKeyPrivate = PrivateKey.generate();
  final signedPreKeyPublic = signedPreKeyPrivate.publicKey;

  // 4. Sign the prekey with Ed25519 identity key
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final timestampBytes = _int64ToBytes(timestamp);
  final messageToSign = Uint8List.fromList([
    ...signedPreKeyPublic.asTypedList,
    ...timestampBytes,
  ]);
  final signedMessage = signingKey.sign(messageToSign);
  final signature = Uint8List.fromList(signedMessage.signature.asTypedList);

  // 5. Generate 100 one-time prekeys
  final List<Map<String, Uint8List>> oneTimePreKeys = [];
  for (int i = 0; i < 100; i++) {
    final otpkPrivate = PrivateKey.generate();
    final otpkPublic = otpkPrivate.publicKey;
    oneTimePreKeys.add({
      'private': Uint8List.fromList(otpkPrivate.asTypedList),
      'public': Uint8List.fromList(otpkPublic.asTypedList),
    });
  }

  // 6. Store ALL private keys in secure storage (identity, identity_dh, signed_prekey, otpks)
  // ... _secureStorage.write per ogni chiave ...
  await _secureStorage.write(key: _keysGenerated, value: 'true');

  // 7. Return public bundle for upload
  return {
    'crypto_version': cryptoVersion,
    'identity_key_public': base64Encode(identityPublic),
    'identity_dh_key_public': base64Encode(Uint8List.fromList(identityDhPublic.asTypedList)),
    'signed_prekey_public': base64Encode(Uint8List.fromList(signedPreKeyPublic.asTypedList)),
    'signed_prekey_signature': base64Encode(signature),
    'signed_prekey_timestamp': timestamp,
    'one_time_prekeys': oneTimePreKeys.map((otpk) => base64Encode(otpk['public']!)).toList(),
  };
}
```

### Upload KeyBundle al backend

```dart
/// Upload public key bundle to server.
/// Call after generateAndStoreKeyBundle().
Future<bool> uploadKeyBundle(Map<String, dynamic> publicBundle) async {
  try {
    debugPrint('[CryptoService] uploadKeyBundle START - keys: ${publicBundle.keys.toList()}');
    await _apiService.post(
      '/encryption/keys/upload/',
      body: publicBundle,
    );
    await _secureStorage.write(key: _keysUploaded, value: 'true');
    debugPrint('[CryptoService] uploadKeyBundle SUCCESS');
    return true;
  } on ApiException catch (e) {
    debugPrint('[CryptoService] uploadKeyBundle FAILED: $e');
    return false;
  } catch (e) {
    debugPrint('[CryptoService] uploadKeyBundle FAILED: $e');
    return false;
  }
}
```

### `initializeKeys()` (ensureKeyBundle / check + genera + upload)

```dart
/// Generate keys and upload in one step.
Future<bool> initializeKeys() async {
  try {
    // Prima verifica sempre il server
    final serverHasKeys = await _verifyKeysOnServer();
    debugPrint('[CryptoService] serverHasKeys: $serverHasKeys');

    if (!serverHasKeys) {
      // Server non ha le chiavi — resetta i flag locali e forza re-upload
      debugPrint('[CryptoService] Server missing keys, clearing local flags...');
      await _secureStorage.delete(key: _keysUploaded);
      await _secureStorage.delete(key: _keysGenerated);
    }

    final alreadyGenerated = await _secureStorage.read(key: _keysGenerated);
    final alreadyUploaded = await _secureStorage.read(key: _keysUploaded);
    final hasPrivateKey = await _secureStorage.read(key: _identityPrivateKey) != null;

    if (alreadyGenerated == 'true' && alreadyUploaded == 'true' && hasPrivateKey) {
      debugPrint('[CryptoService] Keys already initialized and verified on server');
      _initialized = true;
      return true;
    }

    Map<String, dynamic> publicBundle;
    if (alreadyGenerated != 'true' || !hasPrivateKey) {
      debugPrint('[CryptoService] Generating new key bundle...');
      publicBundle = await generateAndStoreKeyBundle();
    } else {
      debugPrint('[CryptoService] Rebuilding public bundle...');
      publicBundle = await _rebuildPublicBundle();
    }

    debugPrint('[CryptoService] Uploading key bundle...');
    return await uploadKeyBundle(publicBundle);
  } catch (e) {
    debugPrint('[CryptoService] initializeKeys error: $e');
    return false;
  }
}
```

### Verifica chiavi sul server (usata da initializeKeys)

```dart
Future<bool> _verifyKeysOnServer() async {
  try {
    final data = await _apiService.get('/encryption/keys/count/');
    final hasBundle = data['has_key_bundle'] == true;
    final preKeyCount = data['available_prekeys'] ?? 0;
    debugPrint('[CryptoService] serverHasKeys: hasBundle=$hasBundle, prekeys=$preKeyCount');
    return hasBundle;
  } catch (e) {
    debugPrint('[CryptoService] _verifyKeysOnServer error: $e');
    return false;
  }
}
```

### Getter isInitialized (checkKeyBundle)

```dart
/// Check if keys have been generated and uploaded.
Future<bool> get isInitialized async {
  final generated = await _secureStorage.read(key: _keysGenerated);
  final uploaded = await _secureStorage.read(key: _keysUploaded);
  return generated == 'true' && uploaded == 'true';
}
```

### Ricostruzione bundle pubblico da storage (usata da initializeKeys)

```dart
Future<Map<String, dynamic>> _rebuildPublicBundle() async {
  final identityPub = await _secureStorage.read(key: _identityPublicKey);
  final identityDhPub = await _secureStorage.read(key: _identityDhPublicKey);
  final spkPub = await _secureStorage.read(key: _signedPreKeyPublic);
  final spkSig = await _secureStorage.read(key: _signedPreKeySignature);
  final spkTs = await _secureStorage.read(key: _signedPreKeyTimestamp);

  final countStr = await _secureStorage.read(key: _otpkCount);
  final count = int.tryParse(countStr ?? '0') ?? 0;

  final List<String> otpkPublics = [];
  for (int i = 0; i < count; i++) {
    final pub = await _secureStorage.read(key: '$_otpkPrefix${i}_public');
    if (pub != null) otpkPublics.add(pub);
  }

  return {
    'crypto_version': cryptoVersion,
    'identity_key_public': identityPub,
    'identity_dh_key_public': identityDhPub,
    'signed_prekey_public': spkPub,
    'signed_prekey_signature': spkSig,
    'signed_prekey_timestamp': int.parse(spkTs ?? '0'),
    'one_time_prekeys': otpkPublics,
  };
}
```

---

## 3. lib/core/services/session_manager.dart

**Percorso:** `lib/core/services/session_manager.dart`

### Inizializzazione (factory + costruttore interno)

```dart
factory SessionManager({
  ApiService? apiService,
  CryptoService? cryptoService,
  FlutterSecureStorage? secureStorage,
}) {
  _instance ??= SessionManager._internal(
    apiService: apiService ?? ApiService(),
    cryptoService: cryptoService ?? CryptoService(apiService: apiService ?? ApiService()),
    secureStorage: secureStorage,
  );
  return _instance!;
}

SessionManager._internal({
  required ApiService apiService,
  required CryptoService cryptoService,
  FlutterSecureStorage? secureStorage,
})  : _apiService = apiService,
      _cryptoService = cryptoService,
      _secureStorage = secureStorage ?? /* ... */;
```

### Ottenere/creare sessione (porta al fetch KeyBundle se non c’è sessione)

```dart
/// Ensure we have an active session with the given user (for sending).
/// If no session exists, performs X3DH handshake and initializes Double Ratchet.
Future<_DoubleRatchetSession> _getOrCreateSession(int otherUserId) async {
  if (_sessions.containsKey(otherUserId)) {
    return _sessions[otherUserId]!;
  }

  final stored = await _secureStorage.read(key: '$_sessionPrefix$otherUserId');
  if (stored != null) {
    try {
      final session = _DoubleRatchetSession.fromJson(jsonDecode(stored) as Map<String, dynamic>);
      _sessions[otherUserId] = session;
      debugPrint('[SessionManager] Loaded existing session for user $otherUserId');
      return session;
    } catch (e) {
      debugPrint('[SessionManager] Failed to load session: $e, creating new one');
    }
  }

  debugPrint('[SessionManager] No session for user $otherUserId, performing X3DH...');
  final session = await _performX3DHAndInitSession(otherUserId);
  _sessions[otherUserId] = session;
  await _saveSession(otherUserId, session);
  return session;
}
```

### Fetch KeyBundle dell’altro utente e X3DH (inizializzazione sessione sender)

```dart
Future<_DoubleRatchetSession> _performX3DHAndInitSession(int otherUserId) async {
  debugPrint('[SessionManager] Fetching key bundle for user $otherUserId...');
  final bundleResponse = await _apiService.get('/encryption/keys/$otherUserId/');

  final otherIdentityKeyPub = Uint8List.fromList(base64Decode(
    (bundleResponse['identity_key'] ?? bundleResponse['identity_key_public']) as String,
  ));
  final otherIdentityDhPub = Uint8List.fromList(base64Decode(
    (bundleResponse['identity_dh_key'] ?? bundleResponse['identity_dh_key_public']) as String,
  ));
  final otherSignedPreKeyPub = Uint8List.fromList(base64Decode(
    (bundleResponse['signed_prekey'] ?? bundleResponse['signed_prekey_public']) as String,
  ));
  final otherSignedPreKeySig = Uint8List.fromList(base64Decode(
    bundleResponse['signed_prekey_signature'] as String,
  ));
  final otherSignedPreKeyTs = bundleResponse['signed_prekey_timestamp'];
  final ts = otherSignedPreKeyTs is int
      ? otherSignedPreKeyTs
      : int.tryParse(otherSignedPreKeyTs?.toString() ?? '0') ?? 0;
  final otherOneTimePreKey = bundleResponse['one_time_prekey'] != null
      ? Uint8List.fromList(base64Decode(bundleResponse['one_time_prekey'] as String))
      : null;
  final otpKeyIdRaw = bundleResponse['one_time_prekey_id'];
  final int? otpKeyId = otpKeyIdRaw is int
      ? otpKeyIdRaw
      : (otpKeyIdRaw != null ? int.tryParse(otpKeyIdRaw.toString()) : null);

  // Verifica firma signed prekey con identity key remota
  try {
    final verifyKey = VerifyKey(otherIdentityKeyPub);
    final timestampBytes = ByteData(8)..setInt64(0, ts);
    final messageToVerify = Uint8List.fromList([
      ...otherSignedPreKeyPub,
      ...timestampBytes.buffer.asUint8List(),
    ]);
    verifyKey.verify(
      signature: Signature(otherSignedPreKeySig),
      message: messageToVerify,
    );
    debugPrint('[SessionManager] Signed prekey verification OK');
  } catch (e) {
    debugPrint('[SessionManager] WARNING: Signed prekey verification failed: $e');
  }

  final ephemeralPrivate = PrivateKey.generate();
  final ephemeralPublic = ephemeralPrivate.publicKey;

  final myIdentityDhPrivate = await _cryptoService.getIdentityDhPrivateKey();
  if (myIdentityDhPrivate == null) {
    throw Exception('Identity DH private key not found');
  }

  // X3DH: DH1, DH2, DH3, eventualmente DH4 con one-time prekey
  final dh1 = _x25519DH(myIdentityDhPrivate, otherSignedPreKeyPub);
  final dh2 = _x25519DH(Uint8List.fromList(ephemeralPrivate.asTypedList), otherIdentityDhPub);
  final dh3 = _x25519DH(Uint8List.fromList(ephemeralPrivate.asTypedList), otherSignedPreKeyPub);

  Uint8List dhConcat;
  if (otherOneTimePreKey != null) {
    final dh4 = _x25519DH(
      Uint8List.fromList(ephemeralPrivate.asTypedList),
      otherOneTimePreKey,
    );
    dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3, ...dh4]);
  } else {
    dhConcat = Uint8List.fromList([...dh1, ...dh2, ...dh3]);
  }

  final sharedSecret = _hkdfSha512(
    ikm: dhConcat,
    info: utf8.encode('SCP_X3DH_SharedSecret_v1'),
    length: 32,
    salt: Uint8List(32),
  );

  debugPrint('[SessionManager] X3DH shared secret derived (${sharedSecret.length} bytes)');

  final myIdentityDhPublic = await _cryptoService.getIdentityDhPublicKey();
  if (myIdentityDhPublic == null) {
    throw Exception('Identity DH public key not found');
  }

  final session = _DoubleRatchetSession.initSender(
    sharedSecret: sharedSecret,
    remotePublicKey: otherSignedPreKeyPub,
    ephemeralPublicKey: Uint8List.fromList(ephemeralPublic.asTypedList),
    identityDhPublicKey: myIdentityDhPublic,
    otpKeyId: otpKeyId,
  );
  debugPrint('[SessionManager] Double Ratchet initialized as sender');
  return session;
}
```

---

## 4. lib/main.dart

**Percorso:** `lib/main.dart`

Non c’è alcuna logica di crypto/key initialization in `main.dart`. L’avvio fa solo:

- `WidgetsFlutterBinding.ensureInitialized()`
- Firebase init e FCM
- Orientamento e system UI
- `runApp(const SecureChatApp())`

L’inizializzazione delle chiavi avviene **solo dopo il login** in `AuthService.login()` con `CryptoService(apiService: _api).initializeKeys()`.

---

## 5. backend/encryption/views.py

**Percorso:** `backend/encryption/views.py`

### Upload KeyBundle — POST `/encryption/keys/upload/`

```python
class UploadKeyBundleView(APIView):
    permission_classes = [IsAuthenticated]
    throttle_classes = [KeyUploadThrottle]

    def post(self, request):
        """
        Upload identity key, signed prekey, and one-time prekeys.
        Called once at registration and when prekeys need replenishing.
        Supports crypto_version=1 (X448/Ed448) and crypto_version=2 (X25519/Ed25519).
        Request body accepts: identity_key_public or identity_key, identity_dh_key_public or identity_dh_key,
        signed_prekey_public or signed_prekey, signed_prekey_signature, signed_prekey_timestamp (v2).
        """
        try:
            crypto_version = int(request.data.get('crypto_version', 2))
            if crypto_version not in (1, 2):
                return Response({'error': 'crypto_version must be 1 or 2.'}, status=status.HTTP_400_BAD_REQUEST)

            # Accept both naming conventions (identity_key_public / identity_key, etc.)
            identity_key = base64.b64decode(
                request.data.get('identity_key_public') or request.data['identity_key']
            )
            identity_dh_key = base64.b64decode(
                request.data.get('identity_dh_key_public') or request.data['identity_dh_key']
            )
            signed_prekey = base64.b64decode(
                request.data.get('signed_prekey_public') or request.data['signed_prekey']
            )
            signed_prekey_signature = base64.b64decode(request.data['signed_prekey_signature'])
            signed_prekey_id = request.data.get('signed_prekey_id', 0)
            signed_prekey_timestamp = request.data.get('signed_prekey_timestamp')
            one_time_prekeys = request.data.get('one_time_prekeys', [])

            # Validate key sizes by crypto_version (32 bytes for v2, 56/57 for v1)
            # ... validazioni lunghezza ...

            # Verify the signed prekey (version-aware)
            is_valid = verify_signed_prekey_versioned(...)
            if not is_valid:
                return Response({'error': 'Firma della signed prekey non valida.'}, status=status.HTTP_400_BAD_REQUEST)

            # Check if identity key changed (SecurityAlert se cambia)
            # ...

            # Save or update key bundle
            bundle, created = UserKeyBundle.objects.update_or_create(
                user=request.user,
                defaults={
                    'crypto_version': crypto_version,
                    'identity_key_public': identity_key,
                    'identity_dh_public': identity_dh_key,
                    'signed_prekey_public': signed_prekey,
                    'signed_prekey_signature': signed_prekey_signature,
                    'signed_prekey_id': signed_prekey_id,
                    'signed_prekey_created_at': created_at,
                }
            )

            # Save one-time prekeys (list of {key_id, public_key} or list of b64 strings)
            for i, otpk in enumerate(one_time_prekeys):
                # ... parse key_id, pub_b64, create OneTimePreKey ...
                _, was_created = OneTimePreKey.objects.update_or_create(
                    user=request.user, key_id=key_id,
                    defaults={'public_key': public_key, 'is_used': False}
                )

            available = OneTimePreKey.objects.filter(user=request.user, is_used=False).count()
            return Response({
                'message': 'Key bundle caricato con successo.',
                'prekeys_created': created_count,
                'prekeys_available': available,
                'signed_prekey_id': signed_prekey_id,
                'crypto_version': crypto_version,
            }, status=status.HTTP_201_CREATED)
        except KeyError as e:
            return Response({'error': f'Campo mancante: {e}'}, status=status.HTTP_400_BAD_REQUEST)
        except Exception as e:
            return Response({'error': 'Errore nel caricamento delle chiavi.'}, status=status.HTTP_400_BAD_REQUEST)
```

### Fetch KeyBundle — GET `/encryption/keys/<user_id>/`

```python
class GetKeyBundleView(APIView):
    permission_classes = [IsAuthenticated]
    throttle_classes = [KeyFetchThrottle]

    def get(self, request, user_id):
        """
        Get another user's key bundle to initiate an encrypted session.
        Consumes one one-time prekey (marked as used).
        Rate limited and logged to detect enumeration/abuse attacks.
        """
        if user_id == request.user.id:
            return Response({'error': 'Non puoi richiedere le tue chiavi.'},
                          status=status.HTTP_400_BAD_REQUEST)

        try:
            bundle = UserKeyBundle.objects.get(user_id=user_id)
        except UserKeyBundle.DoesNotExist:
            return Response({'error': 'L\'utente non ha ancora configurato la cifratura.'},
                          status=status.HTTP_404_NOT_FOUND)

        # Log the fetch for security auditing
        KeyBundleFetchLog.objects.create(
            requester=request.user,
            target_user_id=user_id,
            ip_address=self._get_client_ip(request),
            user_agent=request.META.get('HTTP_USER_AGENT', '')[:500],
        )

        # Get one unused one-time prekey (atomic, mark as used)
        with transaction.atomic():
            otpk = OneTimePreKey.objects.filter(
                user_id=user_id, is_used=False
            ).select_for_update().first()
            if otpk:
                otpk.is_used = True
                otpk.used_by = request.user
                otpk.used_at = timezone.now()
                otpk.save()

        response_data = {
            'user_id': user_id,
            'crypto_version': getattr(bundle, 'crypto_version', 1),
            'identity_key': base64.b64encode(bytes(bundle.identity_key_public)).decode(),
            'identity_dh_key': base64.b64encode(bytes(bundle.identity_dh_public)).decode() if bundle.identity_dh_public else None,
            'signed_prekey': base64.b64encode(bytes(bundle.signed_prekey_public)).decode(),
            'signed_prekey_signature': base64.b64encode(bytes(bundle.signed_prekey_signature)).decode(),
            'signed_prekey_id': bundle.signed_prekey_id,
            'signed_prekey_timestamp': int(bundle.signed_prekey_created_at.timestamp()) if bundle.signed_prekey_created_at else None,
            'one_time_prekey': None,
            'one_time_prekey_id': None,
        }
        if otpk:
            response_data['one_time_prekey'] = base64.b64encode(bytes(otpk.public_key)).decode()
            response_data['one_time_prekey_id'] = otpk.key_id

        response_data['prekeys_remaining'] = OneTimePreKey.objects.filter(user_id=user_id, is_used=False).count()
        # optional: signed_prekey_stale, warning se prekeys basse
        return Response(response_data)
```

### PreKey count (usato dal client in _verifyKeysOnServer) — GET `/encryption/keys/count/`

```python
class PreKeyCountView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """Check prekey availability and signed prekey freshness."""
        count = OneTimePreKey.objects.filter(user=request.user, is_used=False).count()
        bundle = UserKeyBundle.objects.filter(user=request.user).first()
        signed_prekey_stale = bundle.is_signed_prekey_stale() if bundle else True

        return Response({
            'available_prekeys': count,
            'needs_replenish': count < 20,
            'signed_prekey_stale': signed_prekey_stale,
            'has_key_bundle': bundle is not None,
        })
```

---

## 6. backend/encryption/models.py

**Percorso:** `backend/encryption/models.py`

### Modello UserKeyBundle

```python
class UserKeyBundle(models.Model):
    """Stores user's public keys for E2E encryption key exchange"""
    CRYPTO_VERSION_CHOICES = (
        (1, 'X448/Ed448 (legacy)'),
        (2, 'X25519/Ed25519 (production)'),
    )

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='key_bundle'
    )
    crypto_version = models.IntegerField(
        choices=CRYPTO_VERSION_CHOICES,
        default=2,
        help_text='1=X448/Ed448 (legacy), 2=X25519/Ed25519 (production)'
    )
    key_version = models.IntegerField(
        default=1,
        help_text='Incrementato ad ogni rotazione completa del bundle'
    )
    identity_key_public = models.BinaryField(
        help_text='Ed448 public key for identity verification (57 bytes)'
    )
    identity_dh_public = models.BinaryField(
        help_text='X448 public key derived for DH identity operations (56 bytes)',
        null=True
    )
    signed_prekey_public = models.BinaryField(
        help_text='X448 signed prekey public (56 bytes)'
    )
    signed_prekey_signature = models.BinaryField(
        help_text='Ed448 signature over signed prekey'
    )
    signed_prekey_id = models.IntegerField(default=0)
    signed_prekey_created_at = models.DateTimeField(default=timezone.now)
    uploaded_at = models.DateTimeField(auto_now=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'user_key_bundles'

    def is_signed_prekey_stale(self):
        """Signed prekey should be rotated every 7 days"""
        return (timezone.now() - self.signed_prekey_created_at).days >= 7

    def __str__(self):
        return f'KeyBundle for {self.user.email}'
```

---

## Flusso sintetico

1. **Register:** solo POST a `/auth/register/`. Nessuna generazione chiavi.
2. **Login:** POST `/auth/login/` → set tokens e user id → **`CryptoService().initializeKeys()`**.
3. **initializeKeys:** GET `/encryption/keys/count/` → se server non ha bundle, cancella flag locali → se localmente non ci sono chiavi: **generateAndStoreKeyBundle()**, altrimenti ** _rebuildPublicBundle()** → **uploadKeyBundle()** (POST `/encryption/keys/upload/`).
4. **Invio primo messaggio a un utente:** **SessionManager._getOrCreateSession(otherUserId)** → se non c’è sessione: ** _performX3DHAndInitSession(otherUserId)** → GET **`/encryption/keys/<user_id>/`** (fetch KeyBundle) → X3DH e init Double Ratchet sender.
