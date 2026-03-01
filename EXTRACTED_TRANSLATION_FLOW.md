# Codice rilevante: flusso traduzione simultanea e interazione con E2E

Solo il codice legato alla traduzione: backend Argos, cache, toggle, lingua, dove viene tradotto il testo decifrato e come viene mostrato in UI. Niente UI puro (colori, padding).

---

## 1. lib/core/services/translation_service.dart

**Percorso:** `lib/core/services/translation_service.dart`

Il servizio è un singleton che chiama il backend (Argos on-premise) via HTTPS. Il testo viene inviato solo al backend del progetto, non a servizi terzi.

```dart
class TranslationService {
  static final TranslationService _instance = TranslationService._internal();
  factory TranslationService() => _instance;
  TranslationService._internal();

  final Map<String, String> _cache = LinkedHashMap<String, String>();
  static const int _maxCacheSize = 500;

  static const List<String> supportedLanguages = [
    'it', 'en', 'es', 'fr', 'de', 'pt', 'ru', 'zh', 'ja', 'ar', 'ko', 'hi', 'tr', 'pl', 'nl', 'ro'
  ];

  static bool isSupported(String langCode) => supportedLanguages.contains(langCode);

  Future<bool> isModelDownloaded(String langCode) async {
    return isSupported(langCode);
  }

  Future<bool> downloadModel(String langCode) async {
    return isSupported(langCode);
  }

  Future<bool> deleteModel(String langCode) async {
    return true;
  }

  bool get isDownloading => false;

  /// Traduce il testo usando il backend Argos Translate
  Future<String?> translate(String text, String targetLangCode, {String? sourceLangCode}) async {
    if (text.trim().isEmpty) return null;
    if (!isSupported(targetLangCode)) return null;
    if (text.length < 2) return null;

    final cacheKey = '${sourceLangCode ?? 'auto'}:$targetLangCode:$text';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    try {
      final token = ApiService().accessToken;
      if (token == null) return null;

      final response = await http.post(
        Uri.parse('${AppConstants.baseUrl}/translation/translate/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'text': text,
          'target_lang': targetLangCode,
          if (sourceLangCode != null) 'source_lang': sourceLangCode,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final translatedText = data['translated_text']?.toString();
        final detectedSource = data['source_language']?.toString() ?? '';

        if (translatedText == null || translatedText.isEmpty) return null;
        if (translatedText.toLowerCase().trim() == text.toLowerCase().trim()) return null;
        if (detectedSource == targetLangCode) return null;

        if (_cache.length >= _maxCacheSize) {
          _cache.remove(_cache.keys.first);
        }
        _cache[cacheKey] = translatedText;

        return translatedText;
      }
      return null;
    } catch (e) {
      debugPrint('Translation error: $e');
      return null;
    }
  }

  void dispose() {
    _cache.clear();
  }
}
```

- **Chiamata backend:** `POST ${baseUrl}/translation/translate/` con body `{ text, target_lang, source_lang? }` e header `Authorization: Bearer <token>`.
- **Risposta attesa:** `{ translated_text, source_language? }`.
- **Cache:** in-memory `LinkedHashMap` con chiave `sourceLang:targetLang:text`, max 500 entry; se c’è hit non si fa la richiesta HTTP.
- **Toggle / lingua:** non gestiti qui; la preferenza `auto_translate` e la lingua `app_language` sono lette in chat_detail e settings da `SharedPreferences`.

---

## 2. lib/features/chat/screens/chat_detail_screen.dart

**Percorso:** `lib/features/chat/screens/chat_detail_screen.dart`

### Import

```dart
import '../../../core/services/translation_service.dart';
```

### Stato e preferenze

```dart
bool _autoTranslateEnabled = false;
String _userLanguage = 'it';
final Map<int, String> _translatedMessages = {};   // messageId -> testo tradotto
final Map<int, String> _translatedFromLang = {};   // messageId -> 'auto' (lingua rilevata)
```

In `initState` viene chiamato `_loadTranslationPrefs()`.

```dart
Future<void> _loadTranslationPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  if (!mounted) return;
  setState(() {
    _autoTranslateEnabled = prefs.getBool('auto_translate') ?? false;
    _userLanguage = prefs.getString('app_language') ?? 'it';
  });
}
```

### Traduzione messaggio (solo testo decifrato, solo messaggi altrui)

La traduzione avviene **dopo** la decifratura: si usa `message['content']` (plaintext già decifrato in memoria). Il testo non viene mai inviato in chiaro a terzi; va solo al backend del progetto (Argos) via HTTPS autenticato.

```dart
Future<void> _translateMessage(dynamic message) async {
  if (!_autoTranslateEnabled) return;

  final msgId = message is Map ? message['id']?.toString() : null;
  if (msgId == null) return;
  final intId = int.tryParse(msgId) ?? msgId.hashCode;
  if (_translatedMessages.containsKey(intId)) return;

  final text = message is Map
      ? (message['content']?.toString() ?? '')
      : '';
  if (text.isEmpty || text.length < 2) return;
  if (text.startsWith('🔒')) return; // Non tradurre messaggi non decifrati

  final senderIdRaw = message is Map ? (message['sender']?['id'] ?? message['sender_id']) : null;
  final senderId = senderIdRaw is int ? senderIdRaw : (int.tryParse(senderIdRaw?.toString() ?? '') ?? 0);
  if (senderId.toString() == _effectiveCurrentUserId.toString()) return; // Non tradurre i propri messaggi

  try {
    final translated = await TranslationService().translate(text, _userLanguage);

    if (translated != null && translated != text && mounted) {
      setState(() {
        _translatedMessages[intId] = translated;
        _translatedFromLang[intId] = 'auto';
      });
    }
  } catch (e) {
    debugPrint('Translation error (on-device): $e');
  }
}
```

### Dove viene chiamata _translateMessage

1. **WebSocket (nuovo messaggio in tempo reale):** dopo aver aggiunto il messaggio a `_messages` e aver decifrato (e impostato `content`), se `_autoTranslateEnabled` e il messaggio non è dell’utente corrente:
   ```dart
   if (_autoTranslateEnabled) {
     final senderIdInt = ...;
     if (_effectiveCurrentUserId != null && senderIdInt != _effectiveCurrentUserId) {
       _translateMessage(msgData);
     }
   }
   ```

2. **Dopo caricamento messaggi (polling silenzioso):** per ogni messaggio nella lista aggiornata, stessa condizione:
   ```dart
   if (_autoTranslateEnabled) {
     for (final msg in _messages) {
       if (senderIdInt != _effectiveCurrentUserId) _translateMessage(msg);
     }
   }
   ```

3. **Dopo _loadMessages (caricamento iniziale o refresh):** stesso loop su `_messages` con `_autoTranslateEnabled` e filtro su sender.

### Widget messaggio: testo mostrato e riga “tradotto da”

In `_buildMessageContent(Map<String, dynamic> message, bool isMe)`:

- `messageText = message['content']?.toString() ?? ''` è il testo già decifrato (o placeholder).
- Per i messaggi di tipo testo/location/contact (non allegati), il testo mostrato e la presenza della traduzione sono gestiti così:

```dart
final msgIdStr = message['id']?.toString() ?? '';
final msgIdKey = int.tryParse(msgIdStr) ?? msgIdStr.hashCode;
final encryptedB64 = message['content_encrypted_b64']?.toString() ?? '';
final baseText = messageText.isNotEmpty
    ? messageText
    : (encryptedB64.isNotEmpty ? '🔒 Messaggio cifrato' : '(messaggio vuoto)');
final displayText = _translatedMessages[msgIdKey] ?? baseText;
final hasTranslation = _translatedMessages.containsKey(msgIdKey);

return Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(displayText, style: TextStyle(...)),
    if (hasTranslation)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: GestureDetector(
          onTap: () {
            setState(() {
              _translatedMessages.remove(msgIdKey);
              _translatedFromLang.remove(msgIdKey);
            });
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.translate, size: 12, color: Colors.grey[400]),
              const SizedBox(width: 4),
              Text(
                (l10n.t('translated_from')).replaceAll('{lang}', _translatedFromLang[msgIdKey] ?? ''),
                style: TextStyle(fontSize: 10, color: Colors.grey[400], fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
  ],
);
```

- **displayText:** se esiste una traduzione per quel messaggio si mostra quella, altrimenti `baseText` (decifrato o placeholder).
- **Tap sulla riga “tradotto da”:** rimuove la traduzione dalla mappa e si torna a mostrare solo `baseText`.

---

## 3. lib/features/settings/settings_screen.dart

**Percorso:** `lib/features/settings/settings_screen.dart`

### Lettura preferenza

In `_loadProfile()` (o equivalente) la preferenza viene letta da SharedPreferences:

```dart
final prefs = await SharedPreferences.getInstance();
_autoTranslateEnabled = prefs.getBool('auto_translate') ?? false;
```

### Toggle attivazione/disattivazione

```dart
_buildToggleItem(
  icon: Icons.translate_rounded,
  iconColor: const Color(0xFF7C4DFF),
  title: l10n.t('auto_translate'),
  value: _autoTranslateEnabled,
  onChanged: (val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_translate', val);
    setState(() => _autoTranslateEnabled = val);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(val ? l10n.t('auto_translate_enabled') : l10n.t('auto_translate_disabled')),
          ...
        ),
      );
    }
  },
),
```

La preferenza è salvata solo in locale con la chiave `'auto_translate'`; non viene sincronizzata con il backend in questo flusso.

---

## 4. Backend: modulo translation

### backend/translation/views.py

**Percorso:** `backend/translation/views.py`

```python
from .engine import translate_text, get_installed_languages, can_translate

class TranslateMessageView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        text = request.data.get('text', '')
        target_lang = request.data.get('target_lang', '')
        source_lang = request.data.get('source_lang', None)

        if not text or not target_lang:
            return Response({'error': 'text and target_lang required'}, status=status.HTTP_400_BAD_REQUEST)

        result = translate_text(
            text=text,
            target_lang=target_lang,
            source_lang=source_lang,
            user_id=request.user.id,
        )

        return Response(result)


class TranslateBatchView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        messages = request.data.get('messages', [])
        target_lang = request.data.get('target_lang', '')
        # ... max 50 messaggi, loop su msg con text/id, chiama translate_text, restituisce results ...
        return Response({'translations': results, 'target_language': target_lang})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def available_languages(request):
    languages = get_installed_languages()
    return Response({'languages': languages})


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def check_translation_available(request):
    source = request.GET.get('source', '')
    target = request.GET.get('target', '')
    available = can_translate(source or 'en', target)
    return Response({'available': available, 'source': source, 'target': target})
```

L’endpoint usato dall’app è **POST `/api/translation/translate/`** (vedi urls sotto). Il body contiene `text`, `target_lang` e opzionalmente `source_lang`. La risposta è il `result` di `translate_text` (es. `translated_text`, `source_language`, ecc.).

### backend/translation/urls.py

**Percorso:** `backend/translation/urls.py`

```python
urlpatterns = [
    path('translate/', views.TranslateMessageView.as_view(), name='translate-message'),
    path('translate/batch/', views.TranslateBatchView.as_view(), name='translate-batch'),
    path('languages/', views.available_languages, name='translation-languages'),
    path('check/', views.check_translation_available, name='check-translation'),
]
```

Con il prefisso `api/translation/` (in `config/urls.py`):  
`POST /api/translation/translate/` → `TranslateMessageView`.

### backend/translation/engine.py

**Percorso:** `backend/translation/engine.py`

- **Cache:** chiave Redis `trans:{sha256(source_lang:target_lang:text)}`; se assente, cache DB `TranslationCache` (stessa chiave); poi Argos.
- **Lingua sorgente:** se non passata, `detect_language(text)` con `langdetect`; fallback `'en'`.
- **Stesso idioma:** se `source_lang == target_lang` si restituisce il testo invariato.
- **Argos:** `_argos_translate(text, source_lang, target_lang)` con lock; se non esiste la coppia diretta si usa pivot tramite inglese (`_argos_pivot_translate`).
- **Risposta:** `{ translated_text, source_language, target_language, detected_language, cached, char_count [, error] }`.
- **Usage:** `_log_usage(user_id, ...)` scrive in `TranslationUsageLog`.

Funzioni principali:

```python
def translate_text(text, target_lang, source_lang=None, user_id=None) -> dict:
    # Validazione, max length, auto-detect source_lang
    # 1. Redis cache
    # 2. DB TranslationCache
    # 3. _argos_translate() → Redis + DB cache
    return { 'translated_text': ..., 'source_language': ..., 'target_language': ..., 'detected_language': ..., 'cached': ..., 'char_count': ... }

def _argos_translate(text, source_lang, target_lang) -> Optional[str]:
    # argostranslate.translate: get_installed_languages, get_translation, translate
    # Se coppia non installata: _argos_pivot_translate (source→en→target)

def detect_language(text) -> Optional[str]:
    # langdetect.detect, normalizza codici tipo zh-cn → zh
```

### backend/translation/services.py

**Percorso:** `backend/translation/services.py`  
Contenuto attuale: placeholder (`# Placeholder - will be implemented in Chapter 10`). La logica reale è in `engine.py`.

### backend/translation/models.py (solo modelli usati dal flusso)

- **TranslationCache:** cache persistente (cache_key, source_text, translated_text, source_language, target_language, detected_language, char_count, hit_count).
- **TranslationUsageLog:** log uso per user (source_language, target_language, char_count, cached).
- **TranslationPreference:** preferred_language, auto_translate (non usato dal Flutter per il toggle; l’app usa solo SharedPreferences `auto_translate`).

---

## Flusso riassunto (E2E + traduzione)

1. **Decifratura:** il messaggio E2E viene decifrato lato client; `message['content']` diventa il plaintext (o resta placeholder "🔒 Messaggio cifrato").
2. **Quando tradurre:** se `auto_translate` è true e il messaggio non è dell’utente corrente e il testo non è vuoto e non inizia con "🔒", si chiama `_translateMessage(message)`.
3. **Cosa si invia al backend:** solo il **testo già decifrato** (`message['content']`) via `TranslationService().translate(text, _userLanguage)` → POST `/translation/translate/` con `text`, `target_lang`, e opzionale `source_lang`.
4. **Backend:** `TranslateMessageView` → `translate_text()` → cache Redis/DB o Argos; risposta con `translated_text` e `source_language`.
5. **UI:** il testo mostrato è `displayText = _translatedMessages[msgIdKey] ?? baseText`; sotto il messaggio, se c’è traduzione, appare la riga “tradotto da {lang}” (tap per rimuovere la traduzione).
6. **Sicurezza E2E:** la decifratura avviene solo sul device; il backend di traduzione riceve solo il plaintext via HTTPS autenticato e non ha accesso alle chiavi E2E. Per “traduzione solo on-device” andrebbe usato un motore lato client (es. ML Kit) invece di chiamare il backend; oggi il commento in chat_detail dice “100% locale con ML Kit” ma il codice usa `TranslationService()` che chiama il backend Argos.

Per far funzionare la traduzione su simulatore e device mantenendo E2E: verificare che (1) il backend `/translation/translate/` sia raggiungibile (HTTPS, CORS, auth), (2) le lingue usate siano in `TranslationService.supportedLanguages` e che i pacchetti Argos corrispondenti siano installati sul server (engine.py), (3) la preferenza `auto_translate` e `app_language` siano lette correttamente da SharedPreferences in chat_detail e settings.
