# Codice rilevante: badge app e push notifications

Il badge sull’icona non si aggiorna da solo: resta al valore precedente finché l’utente non apre l’app. Dovrebbe aggiornarsi alla ricezione della push e azzerarsi quando l’utente legge i messaggi.

Solo funzioni/metodi pertinenti a badge e push. Niente UI puro.

---

## 1. Gestione badge lato Flutter

### lib/features/home/home_screen.dart

**Import:** `import 'package:flutter_app_badger/flutter_app_badger.dart';`

**Dove viene aggiornato il badge:** solo in `_updateAppBadge()`, che viene chiamata **solo** dopo `_loadData()` e `_loadDataSilent()` (quando l’app è in foreground e riceve la lista conversazioni).

```dart
@override
void dispose() {
  FlutterAppBadger.removeBadge();
  // ...
}
```

```dart
void _updateAppBadge() {
  final totalUnread = _conversations.fold<int>(0, (sum, c) => sum + (c.unreadCount));
  if (totalUnread > 0) {
    FlutterAppBadger.updateBadgeCount(totalUnread);
  } else {
    FlutterAppBadger.removeBadge();
  }
}
```

**Chiamate a _updateAppBadge():**
- In `_loadData()`: dopo `setState` con `_conversations`, `_currentUser`, ecc. (riga ~223).
- In `_loadDataSilent()`: dopo `setState` con le conversazioni aggiornate (riga ~359).

**Origine del valore:** il totale non letti è la somma di `conv.unreadCount` su tutte le conversazioni restituite da `_chatService.getConversations()`. Non viene usato l’endpoint `/notifications/badge/` per il badge sull’icona (quello è usato per `_notificationCount` in UI).

---

### lib/core/services/chat_service.dart

Usato dalla Home per il conteggio “notifiche” in UI; il badge sull’icona invece è basato solo su `_conversations` (unread per conversazione).

```dart
Future<int> getNotificationBadgeCount() async {
  try {
    final data = await _api.get('/notifications/badge/');
    return data['unread_count'] ?? data['count'] ?? 0;
  } catch (e) {
    return 0;
  }
}
```

---

## 2. Configurazione Firebase / FCM (Flutter)

### lib/main.dart

**Setup e gestione notifiche (senza token registration):**

```dart
try {
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(alert: true, badge: true, sound: true);
  final token = await messaging.getToken();
  // ... token registration via API ...

  // Gestione notifiche in foreground
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    debugPrint('[FCM] Foreground message: ${message.notification?.title}');
    // La notifica in foreground è gestita dal polling/WebSocket
  });

  // Gestione tap su notifica
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    debugPrint('[FCM] Opened from notification: ${message.data}');
    // TODO: navigare alla chat corretta
  });
} catch (e) {
  debugPrint('Firebase not configured: $e');
}
```

**Background handler (non aggiorna il badge):**

```dart
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Gestione notifica in background
}
```

- Il badge in background su iOS viene impostato dal sistema in base al payload APNs (`aps.badge`). Se il backend invia un valore sbagliato (o assente), il badge non si aggiorna correttamente.
- In foreground il badge viene aggiornato solo quando la Home chiama `_updateAppBadge()` dopo `_loadData` / `_loadDataSilent()` (polling), non in risposta diretta alla push.

---

## 3. Backend: invio push (chat)

### backend/chat/push_notifications.py

**Inizializzazione Firebase:**

```python
_firebase_app = None

def _get_firebase_app():
    global _firebase_app
    if _firebase_app is not None:
        return _firebase_app
    try:
        import firebase_admin
        from firebase_admin import credentials
        cred_path = os.environ.get('FIREBASE_CREDENTIALS_PATH', '/app/firebase-credentials.json')
        if os.path.exists(cred_path):
            cred = credentials.Certificate(cred_path)
            _firebase_app = firebase_admin.initialize_app(cred)
        else:
            _firebase_app = firebase_admin.initialize_app()
        return _firebase_app
    except Exception as e:
        logger.error('Firebase init error: %s', e)
        return None
```

**Invio push a un utente — payload APNs con badge fisso a 1:**

```python
def send_push_notification(user, title, body, data=None):
    """Invia una notifica push a un utente specifico."""
    if not getattr(user, 'fcm_token', None):
        return False

    try:
        from firebase_admin import messaging

        app = _get_firebase_app()
        if app is None:
            logger.warning('Firebase non inizializzato, skip notifica push')
            return False

        message = messaging.Message(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data=data or {},
            token=user.fcm_token,
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(
                        badge=1,   # <-- SEMPRE 1: non riflette il reale unread count
                        sound='default',
                        content_available=True,
                    ),
                ),
            ),
        )
        response = messaging.send(message)
        logger.info('Push sent to %s: %s', user.username, response)
        return True
    except Exception as e:
        logger.error('Push notification error for %s: %s', user.username, e)
        if 'UNREGISTERED' in str(e) or 'INVALID' in str(e):
            user.fcm_token = None
            user.save(update_fields=['fcm_token'])
        return False


def send_push_to_conversation_participants(conversation, sender, title, body, data=None):
    """Invia push a tutti i partecipanti di una conversazione tranne il mittente."""
    from chat.models import ConversationParticipant

    participants = ConversationParticipant.objects.filter(
        conversation=conversation
    ).exclude(user=sender).select_related('user')

    for participant in participants:
        user = participant.user
        if not getattr(user, 'is_online', False):
            send_push_notification(user, title, body, data)
```

**Problema:** `badge=1` è hardcoded. Il backend non invia il conteggio reale di messaggi non letti (unread per conversazione) nel payload, quindi l’icona non può mostrare il totale corretto e non si “azzera” finché l’utente non apre l’app e la Home non ricalcola il badge da `_conversations`.

---

### backend/chat/views.py — dove parte la push alla creazione messaggio

Dopo la creazione del messaggio (e broadcast WebSocket), viene chiamato il modulo push della chat:

```python
# Invia notifica push ai partecipanti offline
try:
    from chat.push_notifications import send_push_to_conversation_participants
    sender_name = f"{request.user.first_name} {request.user.last_name}".strip() or request.user.username
    if conversation.conv_type == 'group':
        group_name = 'Gruppo'
        try:
            group_name = conversation.group_info.name
        except Exception:
            pass
        push_title = group_name
        push_body = f"{sender_name}: Nuovo messaggio"
    else:
        push_title = sender_name
        push_body = "Nuovo messaggio"
    push_data = {
        'conversation_id': str(conversation.id),
        'message_type': message_type or 'text',
    }
    send_push_to_conversation_participants(conversation, request.user, push_title, push_body, push_data)
except Exception as e:
    import logging
    logging.getLogger(__name__).error('Push notification error: %s', e)
```

Qui non viene calcolato né passato alcun “badge count” per il destinatario; la push usa sempre `badge=1` in `chat/push_notifications.py`.

---

## 4. Backend: WebSocket consumer e push

### backend/chat/consumers.py

**Invio messaggio:** dopo il broadcast del messaggio nel gruppo della conversazione, viene chiamato il metodo che notifica i partecipanti offline (push in coda Celery, modulo `notifications`):

```python
# Broadcast to conversation group
conv_group = f'conv_{conversation_id}'
await self.channel_layer.group_send(conv_group, {
    'type': 'chat.message',
    'message': message_data,
    'sender_id': self.user.id,
})

# Send push notifications to offline participants
await self._notify_offline_participants(conversation_id, message_data)
```

**Metodo che accoda la push (Celery task del modulo notifications):**

```python
@database_sync_to_async
def _notify_offline_participants(self, conversation_id, message_data):
    """Queue push notifications for offline participants"""
    from .models import ConversationParticipant
    from accounts.models import User

    offline_participants = ConversationParticipant.objects.filter(
        conversation_id=conversation_id
    ).exclude(
        user=self.user
    ).select_related('user').filter(
        user__is_online=False,
        user__notification_enabled=True,
    )

    for participant in offline_participants:
        if participant.muted_until and timezone.now() < participant.muted_until:
            continue
        try:
            from notifications.tasks import send_push_notification
            send_push_notification.delay(
                recipient_id=participant.user_id,
                sender_id=self.user.id,
                conversation_id=str(conversation_id),
                message_preview=message_data.get('message_type', 'message'),
            )
        except ImportError:
            pass  # Notifications module not yet implemented
```

Qui la push passa dal task `notifications.tasks.send_push_notification` (modulo `notifications`), non da `chat.push_notifications.send_push_notification`. Quindi ci sono **due flussi**:

1. **Creazione messaggio via REST (chat/views.py)** → `chat.push_notifications.send_push_to_conversation_participants` → `badge=1` fisso.
2. **Messaggio via WebSocket (chat/consumers.py)** → task Celery `notifications.tasks.send_push_notification` → vedi sotto modulo `notifications`.

---

## 5. Backend: modulo notifications (FCM e badge)

### backend/notifications/fcm.py

Qui le push usano il **conteggio reale** di notifiche non lette (modello `Notification`) per il badge APNs:

```python
badge = _get_badge_count(notification.recipient_id)
# ...
apns_aps = messaging.Aps(
    alert=aps_alert,
    sound='default' if (...) else None,
    badge=badge,  # <-- conteggio reale da Notification (is_read=False)
    content_available=is_data_only,
    mutable_content=not is_data_only,
)
```

```python
def _get_badge_count(user_id):
    """Get current unread notification count for badge."""
    from .models import Notification
    return Notification.objects.filter(
        recipient_id=user_id, is_read=False
    ).count()
```

Questo vale per le push inviate dal **modulo notifications** (NotificationService, task Celery, ecc.). Il badge è “unread count” del modello `Notification`, **non** il totale unread per conversazione chat (ConversationParticipant.unread_count).

---

### backend/notifications/views.py — endpoint badge

```python
class BadgeCountView(APIView):
    """
    GET /api/notifications/badge/
    Get unread notification count and breakdown by type.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        data = NotificationService.get_badge_count(request.user.id)
        return Response(data)
```

### backend/notifications/services.py

```python
@classmethod
def get_badge_count(cls, user_id):
    """Get unread notification count and breakdown by type."""
    from django.db.models import Count
    qs = Notification.objects.filter(recipient_id=user_id, is_read=False)
    total = qs.count()
    by_type = dict(
        qs.values('notification_type')
        .annotate(count=Count('id'))
        .values_list('notification_type', 'count')
    )
    return {'unread_count': total, 'by_type': by_type}
```

L’app Flutter usa questo endpoint per `getNotificationBadgeCount()` (es. `_notificationCount` in UI), ma **il badge sull’icona** in Home è calcolato da `_conversations` (somma `unreadCount`), non da questo API.

---

## Riepilogo per il fix del badge

| Dove | Cosa succede oggi | Cosa serve per il fix |
|------|-------------------|------------------------|
| **Flutter** | Badge aggiornato solo in `_updateAppBadge()` dopo `_loadData` / `_loadDataSilent` (app in foreground). In background il badge dipende dal payload della push. | In background: il backend deve inviare il badge corretto in APNs. Opzionale: nel background handler, se la push include un campo `badge` in `data`, chiamare `FlutterAppBadger.updateBadgeCount(...)` o `removeBadge()`. |
| **Backend chat push** (`chat/push_notifications.py`) | Invio push con `badge=1` fisso. | Calcolare l’unread totale per l’utente destinatario (es. somma `ConversationParticipant.unread_count` per quell’utente dopo aver incrementato per il nuovo messaggio) e passare `badge=total_unread` in `messaging.Aps(badge=...)`. |
| **Backend chat views** (`chat/views.py`) | Chiama `send_push_to_conversation_participants` senza badge count. | Opzionale: passare il badge per destinatario a `send_push_to_conversation_participants` / `send_push_notification` se si sposta il calcolo lì. |
| **Backend consumers** | Usa `notifications.tasks.send_push_notification` (modulo notifications). | Il modulo notifications usa già `_get_badge_count` (unread del modello Notification). Se il badge in app deve essere “unread chat” e non “unread Notification”, serve allineare la definizione di badge (stesso conteggio che usa la Home in Flutter) e/o far sì che anche il flusso chat (views + push_notifications) invii lo stesso conteggio. |

In sintesi: per far aggiornare e azzerare correttamente il badge quando arriva una push e quando l’utente legge:

1. **Backend (chat):** in `chat/push_notifications.py`, non usare `badge=1` fisso. Calcolare per ogni destinatario il totale unread (stessa logica usata dalla lista conversazioni, es. somma `ConversationParticipant.unread_count` per quell’utente) e impostare `aps.badge` a quel valore (o 0 se nessun unread).
2. **Flutter (opzionale):** nel background handler, se la push contiene il badge nel payload `data`, aggiornare il badge locale con `FlutterAppBadger` per coerenza (su iOS il sistema può già aggiornare il badge da APNs se il backend invia il valore giusto).
