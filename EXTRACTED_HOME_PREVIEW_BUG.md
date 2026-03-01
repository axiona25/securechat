# Codice rilevante: bug Home preview dopo invio messaggio

Quando l’utente **invia** un messaggio e torna alla Home, la preview mostra "🔒 Messaggio cifrato" invece del testo inviato. Il testo compare solo rientrando in chat e tornando alla Home.

Solo funzioni/metodi pertinenti. Niente import, niente UI puro (colori, padding, icone).

---

## 1. lib/features/chat/screens/chat_detail_screen.dart

### Invio messaggio (`_sendMessage`) — **manca la chiamata a _saveHomePreview**

Dopo il POST, il messaggio viene inserito in `_messages`, il plaintext viene messo in cache con `cacheSentMessage`, ma **non** viene chiamato `_saveHomePreview(_messages)`. La Home quindi non trova nulla in `scp_home_preview_<convId>` e mostra il placeholder cifrato.

```dart
Future<void> _sendMessage() async {
  final text = _textController.text.trim();
  if (text.isEmpty || _conversationId == null || _conversationId!.isEmpty) return;
  // ... typing off, edit branch ...
  _textController.clear();
  setState(() {});
  try {
    final body = <String, dynamic>{ 'message_type': 'text', ... };
    // ... encrypt per otherUser o gruppo ...
    final response = await ApiService().post(
      '/chat/conversations/$_conversationId/messages/',
      body: body,
    );
    if (response != null && response is Map<String, dynamic>) {
      final messageId = response['id']?.toString();
      if (messageId != null && body.containsKey('content_encrypted')) {
        await _sessionManager.cacheSentMessage(messageId, savedText);
        response['content'] = savedText;
      }
      setState(() {
        _messages.insert(0, Map<String, dynamic>.from(response));
        _replyToMessage = null;
        _editingMessageId = null;
      });
      _scrollToBottom();
      SoundService().playMessageSent();
      // MANCA: _saveHomePreview(_messages);
    }
  } catch (e) { ... }
}
```

### Salvataggio preview per la Home (`_saveHomePreview`)

Scrive in `SharedPreferences` la chiave `scp_home_preview_<conversationId>` con `content` e `ts` (timestamp) così la Home può mostrare il testo e verificare che sia ancora l’ultimo messaggio.

```dart
/// Salva il contenuto dell'ultimo messaggio (più recente) per la preview in home.
/// Salva anche il timestamp così la home può verificare che il preview sia per l'ultimo messaggio reale.
/// Chiamato dopo setState con newMessages già reversed (indice 0 = più recente).
Future<void> _saveHomePreview(List<Map<String, dynamic>> newMessages) async {
  if (_conversationId == null || _conversationId!.isEmpty || newMessages.isEmpty) return;
  final lastMsg = newMessages.first;
  final attachments = lastMsg['attachments'] as List? ?? [];
  final hasEncrypted = attachments.isNotEmpty &&
      (attachments[0] is Map) &&
      (attachments[0] as Map)['is_encrypted'] == true;
  String content = lastMsg['content']?.toString()?.trim() ?? '';
  if (content.startsWith('{"type":"location"')) {
    content = '📍 Posizione';
  }
  if (hasEncrypted) {
    content = ChatDetailScreen.encryptedAttachmentPreviewText(lastMsg['message_type']?.toString());
  }
  if (content.isEmpty ||
      content == '🔒 Messaggio cifrato' ||
      content == '🔒 Messaggio non disponibile' ||
      content == '🔒 Messaggio inviato (non disponibile)') {
    return;
  }
  final createdAt = lastMsg['created_at']?.toString();
  if (createdAt == null || createdAt.isEmpty) return;
  final ts = DateTime.tryParse(createdAt)?.toIso8601String() ?? createdAt;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'scp_home_preview_$_conversationId',
    jsonEncode({'content': content, 'ts': ts}),
  );
}
```

### Dove viene chiamata _saveHomePreview

- Dopo caricamento/decifratura messaggi (polling/WebSocket): `_saveHomePreview(_messages)` o `_saveHomePreview(newMessages)`.
- Dopo invio **contatto**: `_saveHomePreview(_messages)` (riga ~4246).
- **Non** dopo invio **testo** in `_sendMessage()` — da qui il bug.

---

## 2. lib/features/home/home_screen.dart

### Come viene costruita la lista e letta la preview

Le conversazioni arrivano da `_chatService.getConversations()`. Per ogni `conv` con `lastMessage` cifrato (`contentEncryptedB64` non vuoto), la Home legge la cache `scp_home_preview_<conv.id>` e, se il timestamp coincide con `lastMessage.createdAt`, imposta `lm.content` con il testo salvato; altrimenti usa il placeholder.

### In _loadData() (primo caricamento / refresh)

```dart
final conversations = results[0] as List<ConversationModel>;
final prefs = await SharedPreferences.getInstance();
for (final conv in conversations) {
  if (conv.lastMessage == null) {
    await prefs.remove('scp_home_preview_${conv.id}');
  }
  final wasCleared = prefs.getBool('scp_chat_cleared_${conv.id}') ?? false;
  if (wasCleared && conv.lastMessage != null) {
    conv.lastMessage!.content = '';
    await prefs.remove('scp_chat_cleared_${conv.id}');
  }
  final lm = conv.lastMessage;
  if (lm != null &&
      lm.contentEncryptedB64 != null &&
      lm.contentEncryptedB64!.isNotEmpty) {
    final lastMsgTs = lm.createdAt?.toIso8601String();
    final raw = prefs.getString('scp_home_preview_${conv.id}');
    if (raw != null && lastMsgTs != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>?;
        final savedTs = decoded?['ts']?.toString();
        final content = decoded?['content']?.toString();
        if (savedTs == lastMsgTs && content != null && content.isNotEmpty) {
          lm.content = content;
        } else {
          lm.content = '🔒 Messaggio cifrato';
        }
      } catch (_) {
        lm.content = '🔒 Messaggio cifrato';
      }
    } else {
      lm.content = '';
    }
  }
}
setState(() {
  _conversations = conversations;
  ...
});
```

### In _loadDataSilent() (polling)

Stessa logica: per ogni `newConv` con last message cifrato, legge `scp_home_preview_${conv.id}`, confronta `savedTs` con `lastMsgTs`; se coincidono e c’è `content`, assegna `lm.content = content`, altrimenti `lm.content = '🔒 Messaggio cifrato'` o `''`.

### Conversione in Map per la preview (`_conversationToMap`)

```dart
Map<String, dynamic> _conversationToMap(ConversationModel c) {
  final lm = c.lastMessage;
  return {
    'id': c.id,
    'last_message': lm != null
        ? {
            'message_type': lm.messageType ?? 'text',
            'content': lm.content ?? '',
            'has_encrypted_attachment': lm.hasEncryptedAttachment,
          }
        : null,
    'unread_count': c.unreadCount,
  };
}
```

### Testo della preview (`_getLastMessagePreviewText`)

```dart
String _getLastMessagePreviewText(Map<String, dynamic> conversation) {
  final lastMessage = conversation['last_message'];
  if (lastMessage == null) return l10n.t('no_message');
  if (lastMessage['has_encrypted_attachment'] == true) {
    return ChatDetailScreen.encryptedAttachmentPreviewText(
      lastMessage['message_type']?.toString(),
    );
  }
  final type = lastMessage['message_type']?.toString() ?? 'text';
  final content = (lastMessage['content']?.toString() ?? '').trim();
  switch (type) {
    case 'image': return 'Foto';
    case 'video': return 'Video';
    // ...
    default: return content.isNotEmpty ? content : l10n.t('no_message');
  }
}
```

Se `content` è vuoto (perché non è stato scritto `scp_home_preview_*` dopo l’invio), qui si ottiene "Nessun messaggio" o il placeholder; la UI poi può mostrare "🔒 Messaggio cifrato" quando il messaggio è cifrato e non c’è cache.

### Widget preview e uso in lista

`_buildLastMessagePreview(conversation)` usa `conversation['last_message']['content']`. La lista passa a `ChatListItem` un `previewBuilder` che fa:

```dart
previewBuilder: (c) => _buildLastMessagePreview(_conversationToMap(c)),
```

Quindi il testo mostrato viene da `conv.lastMessage.content`, che a sua volta è valorizzato solo se prima è stata letta la cache `scp_home_preview_*` e il ts coincide. Se dopo l’invio non si chiama `_saveHomePreview`, quella cache non viene aggiornata e la Home continua a mostrare il placeholder.

---

## 3. lib/features/home/widgets/chat_list_item.dart

### Come viene mostrato il testo della preview

La riga della conversazione usa `previewBuilder` se fornito, altrimenti `conversation.previewTextFor(currentUserId)`.

```dart
Expanded(
  child: previewBuilder != null
      ? previewBuilder!(conversation)
      : Text(
          (conversation.previewTextFor(currentUserId)).trim(),
          ...
        ),
)
```

In Home viene sempre passato `previewBuilder: (c) => _buildLastMessagePreview(_conversationToMap(c))`, quindi il testo arriva da `_buildLastMessagePreview` → `lastMessage['content']`. Quel `content` è `conv.lastMessage.content`, valorizzato in `_loadData` / `_loadDataSilent` dalla cache `scp_home_preview_*`. Se la cache non è stata scritta dopo l’invio, `content` resta vuoto o "🔒 Messaggio cifrato".

### previewTextFor sul model (fallback)

```dart
String previewTextFor(int? currentUserId) {
  if (lastMessage == null) return 'Nessun messaggio';
  final content = (lastMessage!.content ?? '').trim();
  final type = lastMessage!.messageType ?? '';
  final isMe = currentUserId != null && lastMessage!.senderId == currentUserId;
  final prefix = isMe ? 'Tu: ' : '';

  if (content.contains('🔒') || content.contains('Messaggio cifrato')) {
    return '$prefix🔒 Messaggio cifrato';
  }
  if (lastMessage!.hasEncryptedAttachment) {
    return '$prefix📎 Allegato cifrato';
  }
  switch (type) { ... }
  if (content.isNotEmpty) return isMe ? 'Tu: $content' : content;
  return 'Nessun messaggio';
}
```

Qui `lastMessage.content` è lo stesso valore che la Home ha impostato da cache (o lasciato vuoto). Senza scrittura di `scp_home_preview_*` dopo l’invio, `content` non viene aggiornato e la preview resta "🔒 Messaggio cifrato" o vuota.

---

## 4. lib/core/models/conversation_model.dart

### LastMessage (campi usati per la preview)

```dart
class LastMessage {
  final String? id;
  String? content;                    // modificato dalla Home da scp_home_preview_*
  final String? contentEncryptedB64;   // presente se messaggio E2E
  final String? senderName;
  final int? senderId;
  final DateTime? createdAt;          // usato per match ts con cache
  final String? messageType;
  final bool hasEncryptedAttachment;
  final List<dynamic>? statuses;
  ...
}
```

### ConversationModel

```dart
class ConversationModel {
  final String id;
  ...
  final LastMessage? lastMessage;
  ...
  String previewTextFor(int? currentUserId) { ... }  // usa lastMessage.content
}
```

La preview in lista dipende da `lastMessage.content`. Per i messaggi cifrati, `content` viene riempito solo dalla lettura di `scp_home_preview_<id>` in Home, che a sua volta viene scritta da ChatDetail solo quando viene chiamato `_saveHomePreview`.

---

## Causa del bug e fix

- **Causa:** In `_sendMessage()` dopo l’invio di un messaggio di testo (E2E) non viene mai chiamato `_saveHomePreview(_messages)`. La cache `scp_home_preview_<conversationId>` non viene aggiornata. Al ritorno in Home, `_loadData`/`_loadDataSilent` non trovano un preview con timestamp uguale all’ultimo messaggio e lasciano `lm.content` vuoto o "🔒 Messaggio cifrato".
- **Fix:** In `lib/features/chat/screens/chat_detail_screen.dart`, subito dopo `SoundService().playMessageSent();` nel blocco `if (response != null && response is Map<String, dynamic>)` di `_sendMessage()`, aggiungere:
  - `_saveHomePreview(_messages);`
  così che dopo l’inserimento del nuovo messaggio in `_messages` (indice 0 = ultimo) la preview venga scritta e la Home la mostri al successivo caricamento.
