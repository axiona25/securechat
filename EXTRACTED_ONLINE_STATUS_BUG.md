# Codice rilevante per il bug: pallino online/offline sempre grigio

## 1. Frontend — dove viene mostrato il pallino e da dove arriva `is_online`

### `lib/features/home/widgets/chat_list_item.dart`

- **Pallino in lista conversazioni (chat 1:1):** in `_buildSingleAvatar()` si usa `conversation.isOtherOnlineFor(currentUserId)` per il colore (verde/grigio). Il valore viene da `ConversationParticipant.isOnline` dell’altro partecipante.

```dart
  static Color _getStatusColor(bool isOnline) {
    if (isOnline) return const Color(0xFF4CAF50); // Online - verde
    return const Color(0xFF9E9E9E); // Assente - grigio
  }

  Widget _buildSingleAvatar() {
    final isOnline = conversation.isOtherOnlineFor(currentUserId);
    final statusColor = _getStatusColor(isOnline);
    // ...
    child: Container(
      decoration: BoxDecoration(
        color: statusColor,
        shape: BoxShape.circle,
        // ...
      ),
    ),
  }
```

- **Nota:** `_buildHomeMessageStatus()` usa `statuses` (read/delivered), non lo stato online.

---

### `lib/features/home/home_screen.dart`

- **Pallino nella “new chat” (selezione utente):** si usa direttamente `u['is_online']` dall’oggetto utente restituito dall’API (lista utenti per nuova chat).

```dart
  color: _getStatusColor(u['is_online']),
```

- **WebSocket Home:** in `_connectHomeWebSocket()` il listener gestisce solo:
  - `typing.indicator`
  - `conversation.deleted`
  - `session.reset`  
  **Non viene gestito `presence.update`.** Quindi quando un contatto va online/offline, la lista conversazioni non viene aggiornata e il pallino resta grigio.

```dart
  void _connectHomeWebSocket() {
    // ...
    _homeWebSocket!.listen(
      (data) {
        // ...
        if (map['type'] == 'typing.indicator') { ... }
        if (map['type'] == 'conversation.deleted') { ... }
        if (map['type'] == 'session.reset') { ... }
        // MANCA: if (map['type'] == 'presence.update') { ... }
      },
```

---

### `lib/core/models/conversation_model.dart`

- **Lettura di `is_online` dall’altro partecipante:**

```dart
  bool isOtherOnlineFor(int? currentUserId) {
    final other = otherParticipant(currentUserId);
    return other?.isOnline ?? false;
  }

  ConversationParticipant? otherParticipant(int? currentUserId) {
    if (isGroup || participants.isEmpty) return null;
    if (currentUserId == null) {
      return participants.length > 1 ? participants[1] : participants.first;
    }
    for (final p in participants) {
      if (p.userId != currentUserId) return p;
    }
    return participants.isNotEmpty ? participants.first : null;
  }
```

- **Parsing partecipanti dall’API:** in `ConversationParticipant.fromJson` si legge `user['is_online']`. Il backend invia `participants_info` con `user` serializzato da `UserPublicSerializer` (che include `is_online`). Quindi il valore iniziale del pallino viene dall’API liste conversazioni.

```dart
  factory ConversationParticipant.fromJson(Map<String, dynamic> json) {
    final user = json['user'] is Map<String, dynamic> ? json['user'] as Map<String, dynamic> : json;
    return ConversationParticipant(
      userId: user['id'] ?? 0,
      username: username,
      displayName: display,
      avatar: ConversationModel.toAbsoluteUrl(user['avatar']?.toString()),
      isOnline: user['is_online'] ?? false,
    );
  }
```

---

### `lib/features/chat/screens/chat_detail_screen.dart`

- **Aggiornamento presenza in chat:** quando si è dentro una conversazione, `presence.update` viene gestito e si aggiorna solo `_conversation` (participant con `isOnline`). La lista in Home non viene toccata.

```dart
            if (type == 'presence.update') {
              final convId = map['conversation_id']?.toString();
              if (convId != _conversationId) return;
              final userId = map['user_id'];
              final isOnline = map['is_online'] == true;
              final otherId = userId is int ? userId : int.tryParse(userId?.toString() ?? '');
              final currentId = _effectiveCurrentUserId;
              if (otherId != null && otherId != currentId && _conversation != null) {
                final updatedParticipants = _conversation!.participants.map((p) {
                  if (p.userId == otherId) {
                    return ConversationParticipant(
                      userId: p.userId,
                      username: p.username,
                      displayName: p.displayName,
                      avatar: p.avatar,
                      isOnline: isOnline,
                    );
                  }
                  return p;
                }).toList();
                setState(() {
                  _conversation = ConversationModel(
                    // ... con participants: updatedParticipants
                  );
                });
              }
            }
```

---

## 2. Backend — WebSocket presenza e aggiornamento DB

### `backend/chat/consumers.py`

- **Alla connessione:** si imposta l’utente online e si fa broadcast della presenza ai gruppi delle sue conversazioni.

```python
    async def connect(self):
        # ...
        await self.accept()
        # Set user online
        await self._set_online(True)
        await self._broadcast_presence(True)
```

- **Alla disconnessione:** si imposta offline e si notifica.

```python
    async def disconnect(self, close_code):
        if hasattr(self, 'user') and self.user:
            await self.channel_layer.group_discard(self.user_group, self.channel_name)
            for group in self.conversation_groups:
                await self.channel_layer.group_discard(group, self.channel_name)
            await self._set_online(False)
            await self._broadcast_presence(False)
```

- **Scrittura su DB e broadcast:**

```python
    @database_sync_to_async
    def _set_online(self, is_online):
        """Update user online status"""
        from django.utils import timezone
        self.user.refresh_from_db()
        self.user.is_online = is_online
        self.user.last_seen = timezone.now()
        self.user.save(update_fields=['is_online', 'last_seen'])

    async def _broadcast_presence(self, is_online):
        """Broadcast presenza a tutti i partecipanti di ogni conversazione dell'utente."""
        try:
            for group_name in self.conversation_groups:
                conversation_id = group_name[5:] if group_name.startswith('conv_') else None
                await self.channel_layer.group_send(
                    group_name,
                    {
                        'type': 'presence.update',
                        'user_id': self.user.id,
                        'is_online': is_online,
                        'conversation_id': str(conversation_id) if conversation_id else None,
                    },
                )
        except Exception:
            pass

    async def presence_update(self, event):
        """Invia aggiornamento presenza al client."""
        await self.send_json({
            'type': 'presence.update',
            'user_id': event['user_id'],
            'is_online': event['is_online'],
            'conversation_id': event.get('conversation_id'),
        })
```

---

## 3. Backend — come arriva `is_online` nell’API conversazioni

### `backend/chat/serializers.py`

- **Lista conversazioni:** si usa `ParticipantSerializer`, che espone il `user` con `UserPublicSerializer`. Quindi ogni partecipante ha `user` con `is_online` e `last_seen`.

```python
class ParticipantSerializer(serializers.ModelSerializer):
    user = UserPublicSerializer(read_only=True)

    class Meta:
        model = ConversationParticipant
        fields = ['user', 'role', 'joined_at', 'muted_until', 'is_pinned', 'unread_count', 'is_blocked']

class ConversationListSerializer(serializers.ModelSerializer):
    participants_info = serializers.SerializerMethodField()
    # ...

    def get_participants_info(self, obj):
        participants = obj.conversation_participants.select_related('user').all()
        return ParticipantSerializer(participants, many=True).data
```

### `backend/accounts/serializers.py`

- **User pubblico (usato nei partecipanti):** include `is_online` e `last_seen`.

```python
class UserPublicSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ['id', 'username', 'first_name', 'last_name', 'avatar', 'bio', 'is_online', 'last_seen']
```

### `backend/accounts/models.py`

- **Campo sul modello User:**

```python
is_online = models.BooleanField(default=False)
```

---

## Conclusione sul bug

1. **Backend:**  
   - Alla connect/disconnect WebSocket si aggiorna correttamente `User.is_online` e si invia `presence.update` ai gruppi delle conversazioni.  
   - L’API lista conversazioni restituisce `is_online` tramite `UserPublicSerializer` nei partecipanti.  
   Quindi lato server il flusso presenza e API è coerente.

2. **Frontend — lista in Home:**  
   - Il pallino in `chat_list_item` usa `conversation.isOtherOnlineFor(currentUserId)` → `other?.isOnline`, che a sua volta viene da `ConversationParticipant.fromJson` → `user['is_online']` al momento del fetch.  
   - In **Home** il WebSocket non gestisce `presence.update`: quando un contatto si connette/disconnette, la lista `_conversations` non viene aggiornata e il pallino resta quello del primo caricamento (solitamente grigio se l’altro non era ancora connesso).

3. **Frontend — dentro la chat:**  
   - In `chat_detail_screen` `presence.update` viene gestito e si aggiorna solo `_conversation` per quella schermata; non si propaga alla lista della Home.

**Fix consigliato:** in `lib/features/home/home_screen.dart`, nel listener di `_homeWebSocket`, aggiungere la gestione di `map['type'] == 'presence.update'` e aggiornare in `_conversations` il partecipante corrispondente (`user_id` / `conversation_id`) impostando `isOnline` a `map['is_online'] == true`, poi `setState` per far ridisegnare la lista (e quindi il pallino).
