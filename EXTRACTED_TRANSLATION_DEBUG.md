# Codice rilevante per debug: traduzione automatica non funziona

Messaggi decifrati ma non tradotti, nessun log da TranslationService. Solo le funzioni e i punti di chiamata utili al debug.

---

## 1. lib/features/chat/screens/chat_detail_screen.dart

### Stato e dove vengono letti

```dart
bool _autoTranslateEnabled = false;
String _userLanguage = 'it';
// ...
final Map<int, String> _translatedMessages = {};
final Map<int, String> _translatedFromLang = {};
```

- **initState:** viene chiamato `_loadTranslationPrefs();` (senza await). Le preferenze sono caricate in modo asincrono; quando finiscono viene fatto `setState` con i valori letti.

### _loadTranslationPrefs()

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

- Se `!mounted` prima del setState, il toggle resta false e la lingua resta 'it'.
- Valori usati: `_autoTranslateEnabled` (per decidere se chiamare _translateMessage), `_userLanguage` (target della traduzione).

### _translateMessage()

```dart
Future<void> _translateMessage(dynamic message) async {
  if (!_autoTranslateEnabled) return;

  final msgId = message is Map ? message['id']?.toString() : null;
  if (msgId == null) return;
  final intId = int.tryParse(msgId) ?? msgId.hashCode;
  if (_translatedMessages.containsKey(intId)) return;

  // Ottieni il testo decifrato
  final text = message is Map
      ? (message['content']?.toString() ?? '')
      : '';
  if (text.isEmpty || text.length < 2) return;
  if (text.startsWith('🔒')) return; // Non tradurre messaggi non decifrati

  // Non tradurre i propri messaggi
  final senderIdRaw = message is Map ? (message['sender']?['id'] ?? message['sender_id']) : null;
  final senderId = senderIdRaw is int ? senderIdRaw : (int.tryParse(senderIdRaw?.toString() ?? '') ?? 0);
  if (senderId.toString() == _effectiveCurrentUserId.toString()) return;

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

Possibili cause di “nessuna traduzione”:
- `_autoTranslateEnabled` è false (prefs non ancora caricate o mai salvate).
- `message['content']` vuoto o breve (< 2 caratteri) o che inizia con "🔒" (messaggio non decifrato).
- Messaggio proprio (senderId == _effectiveCurrentUserId).
- Già tradotto (`_translatedMessages.containsKey(intId)`).
- `TranslationService().translate()` restituisce null (vedi sotto): nessun log in TranslationService tranne in catch.

### Punto 1 — WebSocket (nuovo messaggio in tempo reale)

```dart
if (type == 'chat.message') {
  final msgData = map['message'] as Map<String, dynamic>?;
  if (msgData != null && mounted) {
    // ...
    setState(() {
      _messages.insert(0, msgData);
    });
    // ...
    if (_autoTranslateEnabled) {
      final sender = msgData['sender'];
      final senderId = sender is Map ? (sender as Map)['id'] : null;
      final senderIdInt = senderId is int ? senderId : int.tryParse(senderId?.toString() ?? '');
      if (_effectiveCurrentUserId != null && senderIdInt != _effectiveCurrentUserId) {
        _translateMessage(msgData);
      }
    }
  }
}
```

- **Attenzione:** per messaggi E2E, `msgData` arriva dal server e spesso **non** contiene il plaintext in `content` (es. c’è `content_encrypted_b64`). La decifratura può avvenire dopo (es. in _loadMessages o quando si renderizza). Quindi qui `msgData['content']` può essere vuoto o "🔒 Messaggio cifrato" e _translateMessage esce subito (testo vuoto o che inizia con 🔒).

### Punto 2 — Polling silenzioso (aggiornamento messaggi)

```dart
// Dopo setState con _messages aggiornati (merge da newMessages, con content eventualmente decifrato)
_markAsRead();
_saveHomePreview(newMessages);
if (_autoTranslateEnabled) {
  for (final msg in _messages) {
    final sender = msg['sender'];
    final senderId = sender is Map ? (sender as Map)['id'] : null;
    final senderIdInt = senderId is int ? senderId : int.tryParse(senderId?.toString() ?? '');
    if (_effectiveCurrentUserId != null && senderIdInt != _effectiveCurrentUserId) {
      _translateMessage(msg);
    }
  }
}
```

- Qui i messaggi in `_messages` possono avere già `content` decifrato (se il polling restituisce/elabora il plaintext). Se invece `content` resta vuoto o "🔒", _translateMessage non farà nulla.

### Punto 3 — _loadMessages (caricamento iniziale o refresh)

```dart
newMessages = newMessages.reversed.toList();
setState(() {
  _messages = newMessages;
  if (!silent) _loading = false;
});
_preloadAttachmentCaptionsFromPrefs();
// ...
_saveHomePreview(newMessages);
if (_autoTranslateEnabled) {
  for (final msg in _messages) {
    final sender = msg['sender'];
    final senderId = sender is Map ? (sender as Map)['id'] : null;
    final senderIdInt = senderId is int ? senderId : int.tryParse(senderId?.toString() ?? '');
    if (_effectiveCurrentUserId != null && senderIdInt != _effectiveCurrentUserId) {
      _translateMessage(msg);
    }
  }
}
```

- Stesso discorso: la traduzione parte solo se in `msg` è già presente un `content` decifrato (non vuoto, non "🔒", lunghezza ≥ 2). L’ordine tra “decifratura messaggi” e questo blocco in _loadMessages è importante: se la decifratura è asincrona e avviene dopo, in questo punto `msg['content']` può non essere ancora il testo in chiaro.

---

## 2. lib/core/services/translation_service.dart — translate() completa

```dart
Future<String?> translate(String text, String targetLangCode, {String? sourceLangCode}) async {
  if (text.trim().isEmpty) return null;
  if (!isSupported(targetLangCode)) return null;
  if (text.length < 2) return null;

  // Cache check
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
```

**Log attuali:** c’è un solo `debugPrint` in tutto il metodo, e solo nel `catch`. Quindi:
- Se non vedi nessun log, o `translate()` non viene mai chiamata, oppure viene chiamata ma restituisce null senza eccezioni (early return o status != 200 o risposta senza translated_text).
- Non c’è traccia di: ingresso in translate, testo/lingua, cache hit, token assente, status code, corpo risposta, o motivo del return null.

Per il debug conviene aggiungere `debugPrint` (o log) almeno:
- all’ingresso: testo.length, targetLangCode, _autoTranslateEnabled (se passi dal chiamante).
- dopo ogni `return null`: motivo (testo vuoto, lingua non supportata, cache hit, token null, status != 200, translatedText null/vuoto, stesso testo, source == target).
- in caso di successo: breve conferma che è stata restituita una traduzione.

---

## Checklist debug veloce

1. **Toggle e lingua:** dopo aver attivato “Traduzione automatica” in Impostazioni, verificare che in SharedPreferences ci siano `auto_translate == true` e `app_language` impostato (es. `it`). In chat_detail, subito prima di chiamare _translateMessage, loggare `_autoTranslateEnabled` e `_userLanguage`.
2. **Chi chiama _translateMessage:** aggiungere un `debugPrint` all’inizio di _translateMessage (es. msgId, length di message['content'], inizio di content) per confermare che viene invocata e con quale contenuto.
3. **Contenuto messaggio:** per i messaggi E2E verificare **quando** viene assegnato `message['content']` (decifratura). Se la decifratura è asincrona e avviene dopo il blocco che chiama _translateMessage, bisogna o chiamare _translateMessage dopo che il messaggio è stato decifrato, o innescare la traduzione dal punto in cui si imposta `content` dopo la decifratura.
4. **TranslationService:** aggiungere i log in `translate()` come sopra per capire se la richiesta parte e perché eventualmente restituisce null (token, status, body, stessi testo/lingua).
