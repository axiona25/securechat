# E2E Allegati — Analisi e cosa manca

Ecco il codice relativo agli allegati in SecureChat. Analizzalo e verifica cosa manca per implementare la cifratura E2E end-to-end sugli allegati.

---

## 1. Backend — Modello e endpoint allegati

### Modello `Attachment` (backend/chat/models.py)

```python
class Attachment(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    message = models.ForeignKey(
        Message, on_delete=models.CASCADE, related_name='attachments',
        null=True, blank=True,
        help_text='Null until message is sent (upload-first flow for E2EE media)'
    )
    file = models.FileField(upload_to='attachments/%Y/%m/')
    file_name = models.CharField(max_length=255)
    file_size = models.BigIntegerField(default=0)
    mime_type = models.CharField(max_length=100, default='application/octet-stream')
    thumbnail = models.ImageField(upload_to='thumbnails/%Y/%m/', null=True, blank=True)
    duration = models.FloatField(null=True, blank=True)
    width = models.IntegerField(null=True, blank=True)
    height = models.IntegerField(null=True, blank=True)
    encryption_key_encrypted = models.BinaryField(null=True, blank=True)
    # E2EE media (zero-knowledge)
    encrypted_file_key = models.TextField(blank=True, default='')
    encrypted_metadata = models.TextField(blank=True, default='')
    file_hash = models.CharField(max_length=64, blank=True, default='')
    is_encrypted = models.BooleanField(default=False)
    uploaded_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, ...)
    created_at = models.DateTimeField(auto_now_add=True)
```

### Endpoint E2E (media_views.py + media_urls.py)

- **POST `/api/chat/media/upload/`** — `EncryptedMediaUploadView`  
  Body: `encrypted_file`, `encrypted_thumbnail` (opz.), `conversation_id`, `encrypted_file_key`, `encrypted_metadata`, `file_hash`, `encrypted_file_size`.  
  Risposta: `attachment_id`, `encrypted_file_url`, `encrypted_thumbnail_url` (opz.).

- **GET `/api/chat/media/<uuid:attachment_id>/download/`** — `EncryptedMediaDownloadView`  
  Restituisce il blob cifrato; header `X-File-Hash`, `X-Is-Encrypted`.

- **GET `/api/chat/media/<uuid:attachment_id>/thumbnail/`** — `EncryptedThumbnailDownloadView`  
  Thumbnail cifrato.

- **GET `/api/chat/media/<uuid:attachment_id>/key/`** — `AttachmentKeyView`  
  Restituisce `encrypted_file_key`, `encrypted_metadata`, `file_hash`, `is_encrypted` per decifrare lato client.

### Endpoint legacy (views.py + urls.py)

- **POST `/api/chat/upload/`** — `AttachmentUploadView`  
  Body: `file`, `message_id`, `type` (image/video/audio/file).  
  Crea un allegato **non cifrato** collegato al messaggio; risposta = `AttachmentSerializer.data` (id, file, file_name, file_size, mime_type, thumbnail, duration, width, height, created_at).

### Serializer allegato (serializers.py)

```python
class AttachmentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Attachment
        fields = ['id', 'file', 'file_name', 'file_size', 'mime_type',
                  'thumbnail', 'duration', 'width', 'height', 'created_at']
```

Il serializer **non** espone `encrypted_file_key`, `encrypted_metadata`, `file_hash`, `is_encrypted` nella lista messaggi; le chiavi si prendono da `/api/chat/media/<id>/key/`.

---

## 2. Frontend — Servizio upload

**File:** `lib/core/services/media_upload_service.dart`

- **`encryptAndUpload(...)`**  
  Parametri: `fileBytes`, `fileName`, `mimeType`, `conversationId`, **`SecretKey sessionKey`**, `thumbnailBytes` (opz.), `onProgress`.  
  Flusso: genera `fileKey` → cifra file (e thumbnail) con `MediaEncryptionService` → cifra `fileKey` con `sessionKey` → cifra metadata con `fileKey` → POST multipart a `/chat/media/upload/` con `encrypted_file`, `encrypted_thumbnail`, `conversation_id`, `encrypted_file_key`, `encrypted_metadata`, `file_hash`, `encrypted_file_size`.  
  Ritorna `MediaUploadResult`: `attachmentId`, `encryptedFileUrl`, `encryptedThumbnailUrl`, `encryptedFileKeyB64`, `encryptedMetadataB64`, `fileHash`.

- **`downloadAndDecrypt(...)`**  
  Parametri: `attachmentId`, **`SecretKey sessionKey`**, `onProgress`.  
  Flusso: GET `/chat/media/<id>/key/` → decifra `fileKey` con `sessionKey` → decifra metadata → GET download → decifra blob → verifica hash.

- **`downloadAndDecryptThumbnail(...)`**  
  Parametri: `attachmentId`, **`SecretKey fileKey`** (non sessionKey).

**Problema:** `sessionKey` è un `SecretKey` (package `cryptography`). Il `SessionManager` (Double Ratchet) espone solo `encryptMessage`/`decryptMessage` per testo e non una chiave di sessione raw. Manca un modo per ottenere un `SecretKey` dalla sessione Double Ratchet da passare a `encryptAndUpload` / `downloadAndDecrypt`.

---

## 3. Frontend — Invio messaggio con allegato

**File:** `lib/features/chat/screens/chat_detail_screen.dart`

- **`_showAttachmentBottomSheet()`** — Apre il bottom sheet (galleria, camera, video, documento, ecc.).
- **`_pickFile()`** — Usa `FilePicker.platform.pickFiles` → chiama `_uploadAndSendFile(File(...), 'file')`.
- **`_uploadAndSendFile(File file, String messageType)`** (flusso attuale, **non E2E**):
  1. Crea il messaggio **prima** con POST a `/chat/conversations/<id>/messages/` con body `{ "content": fileName, "message_type": messageType }` (testo in chiaro).
  2. Riceve `message_id` dalla risposta.
  3. Upload **legacy** con POST a **`/chat/upload/`** (non `/api/chat/media/upload/`): `message_id`, `type`, `file` (multipart). Il server salva l’allegato in chiaro e lo collega al messaggio.
  4. Dopo successo: `_forceReloadMessages()`.

**Non** viene usato `MediaUploadService.encryptAndUpload` né l’endpoint E2E `/api/chat/media/upload/`. Il messaggio ha solo `content` = nome file e `message_type`; l’allegato arriva via endpoint legacy senza cifratura.

---

## 4. Frontend — Visualizzazione allegato

- **`_buildAttachmentContent(message, isMe)`** (chat_detail_screen.dart)  
  Legge `message['attachments']`, prende il primo allegato. Per `image`: `Image.network(_buildDirectMediaUrl(att['file']|att['thumbnail']))`. Per `video`: thumbnail/stream con `_buildDirectMediaUrl` / `_buildStreamMediaUrl`. Per `file`: nome, mime, tap → `_openFileUrl(fileUrl, fileName:, mimeType:, attachmentId:)`.

- **`_openFileUrl`** → Push a **`DocumentViewerScreen`** con `fileUrl`, `fileName`, `mimeType`, `attachmentId`.  
  `DocumentViewerScreen` scarica/apre il file tramite URL; non usa `MediaUploadService.downloadAndDecrypt` né passa `attachmentId` a un servizio E2E.

- **`_buildDirectMediaUrl`** — Costruisce URL verso `/media/` (base URL media). Gli allegati legacy hanno `file` come path Django (es. `attachments/2025/02/xxx`); per allegati E2E il backend restituirebbe URL tipo `/api/chat/media/<id>/download/` (blob cifrato), che andrebbe gestito con download + decifratura lato client.

Quindi: **visualizzazione e download sono pensati per file in chiaro** (URL diretto). Per E2E servirebbe: riconoscere allegato cifrato (es. `is_encrypted` o assenza di URL “direct”) → chiamare `downloadAndDecrypt` con la session key → mostrare/aprire il file decifrato (e salvare in cache locale se serve).

---

## 5. SessionManager — Metodi pubblici

**File:** `lib/core/services/session_manager.dart`

| Metodo | Descrizione |
|--------|-------------|
| `encryptMessage(int otherUserId, String plaintext)` | Ritorna `Uint8List` (wire format: 2B headerLen + header + ciphertext). Usato per messaggi di testo. |
| `decryptMessage(int senderUserId, Uint8List combinedPayload)` | Decifra e ritorna `String` plaintext. |
| `cacheSentMessage(String messageId, String plaintext)` | Salva plaintext in memoria e SharedPreferences `scp_msg_cache_$messageId`. |
| `getCachedPlaintext(String messageId)` | Legge da cache (memoria poi disco). |
| `markDecryptFailed(String messageId)` | Marca messaggio come fallito (persistito). |
| `isDecryptFailed(String messageId)` | Controlla se il messaggio è marcato fallito. |
| `hasCachedPlaintext(String messageId)` | Ritorna se il messaggio è in cache. |
| `hasSession(int otherUserId)` | Ritorna se esiste una sessione per l’utente. |
| `clearAllSessions()` | Svuota sessioni e cache. |

**Non** c’è: `getSessionKey()`, `exportKey()`, o simile che restituisca un `SecretKey` per usarlo con `MediaEncryptionService.encryptFileKey` / `decryptFileKey`. Il Double Ratchet è usato solo per cifrare/decifrare payload di messaggi (testo), non per esportare una chiave condivisa.

---

## Domande e risposte

- **L’upload allegato restituisce un ID/URL dal server?**  
  - **E2E:** sì: `attachment_id`, `encrypted_file_url`, opzionale `encrypted_thumbnail_url`.  
  - **Legacy:** la risposta è l’oggetto allegato serializzato (id, file, file_name, file_size, mime_type, thumbnail, …); l’URL file è nel campo `file` (path/URL).

- **Il messaggio con allegato ha un campo specifico?**  
  Sì: il messaggio ha `attachments` (lista di allegati). Il serializer messaggio include `attachments = AttachmentSerializer(many=True, read_only=True)`. In E2E l’allegato può avere `message=None` fino al “link” del messaggio (upload-first).

- **Gli allegati sono già visibili in UI?**  
  Sì: immagini, video, file e documenti vengono mostrati in chat tramite `_buildAttachmentContent` e aperti con `DocumentViewerScreen`. Il flusso attuale è per file **non** cifrati (URL diretto o path backend).

- **Che tipi di file sono supportati?**  
  Backend legacy: image (jpeg, png, gif, webp), video (mp4, quicktime, webm, x-msvideo, ogg), audio (mpeg, ogg, mp4, webm, wav), file (generico, max 50 MB). E2E (media_views): qualsiasi blob (max 100 MB file, 512 KB thumbnail).

---

## Cosa manca per E2E allegati

1. **Session key per media**  
   Derivare (o esporre) da SessionManager/Double Ratchet un `SecretKey` da usare con `MediaEncryptionService.encryptFileKey` / `decryptFileKey` (es. chiave condivisa dalla root key della sessione, o messaggio “key export” cifrato con il ratchet). Senza questo, `encryptAndUpload` e `downloadAndDecrypt` non sono utilizzabili.

2. **Invio: usare flusso E2E in chat_detail_screen**  
   Sostituire (o affiancare) il flusso “crea messaggio → upload legacy” con: ottenere session key per l’altro utente → `MediaUploadService.encryptAndUpload` → creare messaggio con riferimento all’`attachment_id` (e eventuale caption cifrato con `encryptMessage`). Backend: supportare creazione messaggio con `attachment_ids` e senza inviare file nel body del messaggio.

3. **Ricezione e UI**  
   Per messaggi con allegati E2E (`is_encrypted` o assenza di URL “direct”): chiamare GET `/api/chat/media/<id>/key/` e `downloadAndDecrypt` con la session key del mittente; poi mostrare/aprire il file decifrato (e gestire cache locale/thumbnail decifrato).

4. **Backend: creazione messaggio con allegati E2E**  
   Endpoint “send message” deve accettare uno o più `attachment_id` già caricati con `/api/chat/media/upload/` e collegare quegli allegati al messaggio (impostare `attachment.message_id`). Serializer messaggio: esporre almeno `is_encrypted` (e possibilmente link a download/key) per ogni attachment così il client sa se usare il flusso E2E.

5. **DocumentViewerScreen (e preview)**  
   Se `attachmentId` corrisponde a allegato E2E: non usare `fileUrl` come URL diretto; usare `MediaUploadService.downloadAndDecrypt` con session key e aprire il file decifrato (file temporaneo o in-memory), e gestire errori (sessione mancante, decifratura fallita).

---

*Generato dall’analisi del codebase SecureChat (backend Django + Flutter).*
