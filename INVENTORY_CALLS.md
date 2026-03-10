# Inventario: chiamate audio/video in SecureChat

## 1. Frontend Flutter

### File e codice relativi alle chiamate

| Path | Contenuto | Stato |
|------|-----------|--------|
| **lib/features/home/home_screen.dart** | Tab "Chiamate" nella bottom bar: `BottomNavItem(icon: Icons.call_outlined, activeIcon: Icons.call, label: l10n.t('calls'))`. Il body **non** dipende da `_currentNavIndex`: per index 0, 1, 2 viene sempre mostrata la stessa schermata (lista chat + header + ChatTabBar + ChatListView). Tap sul tab cambia solo l’indice selezionato. | **Placeholder/stub** — tab presente, nessuna schermata dedicata alle chiamate |
| **lib/features/chat/screens/chat_detail_screen.dart** | In AppBar `actions`: pulsante telefono (`Icons.phone_rounded`) e pulsante video (`Icons.videocam_rounded`). **Phone:** `onPressed` → `ScaffoldMessenger.showSnackBar('Chiamata audio: coming soon')`. **Video:** `onPressed` → `ScaffoldMessenger.showSnackBar('Videochiamata: coming soon')`. | **Placeholder/stub** — solo SnackBar "coming soon", nessuna logica chiamate |
| Nessun altro file | Nessun `CallScreen`, `CallService`, `IncomingCall`, `OutgoingCall`, WebRTC, signaling, o servizio chiamate. | **Non esiste** |

### Dipendenze esterne (pubspec.yaml)

- **flutter_webrtc, agora, jitsi, twilio, webrtc, voip:** non presenti.
- **video_player, chewie:** presenti per riproduzione video (messaggi), non per live call.
- **Conclusione:** nessun pacchetto per chiamate/WebRTC/VoIP. **Non esiste** integrazione SDK chiamate.

---

## 2. Backend Django

### Modulo `calls`

| Path | Contenuto | Stato |
|------|-----------|--------|
| **backend/calls/models.py** | `Call` (conversation, call_type audio/video, status ringing/ongoing/ended/missed/rejected/busy/failed, initiated_by, is_group_call, timestamps, duration), `CallParticipant` (call, user, joined_at, left_at, is_muted, is_video_off, is_speaker_on), `ICEServer` (server_type stun/turn, url, username, credential, `to_webrtc_config()`). | **Implementato** |
| **backend/calls/views.py** | `CallLogView` (GET log con filtri type/status), `CallDetailView` (GET dettaglio per call_id), `ICEServersView` (GET config STUN/TURN per WebRTC), `MissedCallsCountView` (GET conteggio missed). | **Implementato** |
| **backend/calls/urls.py** | `log/`, `<uuid:call_id>/`, `ice-servers/`, `missed-count/`. | **Implementato** |
| **backend/calls/serializers.py** | `CallParticipantSerializer`, `CallSerializer`, `CallLogSerializer`. | **Implementato** |
| **backend/calls/consumers.py** | `CallSignalingConsumer` (WebSocket `ws/calls/`). Azioni: `initiate_call`, `accept_call`, `reject_call`, `offer`, `answer`, `ice_candidate`, `end_call`, `toggle_mute`, `toggle_video`, `toggle_speaker`. Crea record Call, notifica partecipanti, invia push (se disponibile), inoltra SDP/ICE tra peer. Supporto 1-to-1 e group call. | **Implementato** |
| **backend/calls/routing.py** | `re_path(r'ws/calls/$', CallSignalingConsumer.as_asgi())`. | **Implementato** |
| **backend/calls/admin.py** | `CallAdmin`, `CallParticipantAdmin` registrati. | **Implementato** |

### Integrazioni esterne al modulo calls

| Path | Contenuto | Stato |
|------|-----------|--------|
| **backend/config/urls.py** | `path('api/calls/', include('calls.urls'))`. | **Implementato** |
| **backend/config/asgi.py** | `calls_ws` (routing WebSocket calls) incluso nella routing ASGI. | **Implementato** |
| **backend/notifications/helpers.py** | `notify_incoming_call()`, `notify_missed_call()` (creano notifiche + push per chiamate). | **Implementato** |
| **backend/notifications/models.py** | `NotificationType.INCOMING_CALL`, `MISSED_CALL`; preferenze `incoming_call`, `missed_call`. | **Implementato** |
| **backend/notifications/fcm.py** | Gestione `incoming_call` (priorità alta, badge 'calls'). | **Implementato** |

---

## 3. Tab "Chiamate" (bottom bar Home)

- **Cosa mostra:** la stessa schermata della tab "Chat" (lista conversazioni). Non c’è condizionale sul body in base a `_currentNavIndex` per index 1.
- **Stato:** **Placeholder** — voce di menu presente, nessuna lista chiamate né UI dedicata.

---

## 4. Pulsanti 📞 e 📹 nell’header della chat

- **Posizione:** `lib/features/chat/screens/chat_detail_screen.dart`, AppBar `actions`.
- **📞 (Icons.phone_rounded):** `onPressed` → `showSnackBar('Chiamata audio: coming soon')`. Nessuna chiamata API né WebSocket.
- **📹 (Icons.videocam_rounded):** `onPressed` → `showSnackBar('Videochiamata: coming soon')`. Nessuna logica.
- **Stato:** **Placeholder/stub** — solo messaggio "coming soon".

---

## 5. pubspec.yaml — pacchetti chiamate/WebRTC/VoIP

- **Cercati:** webrtc, WebRTC, agora, Agora, jitsi, Jitsi, twilio, Twilio, voip, VoIP, flutter_webrtc, peerconnection, signaling (come dipendenze).
- **Risultato:** nessuna dipendenza per chiamate o WebRTC. Solo `video_player` e `chewie` per video (contenuti), non per live call.
- **Stato:** **Non esiste** — nessun pacchetto per chiamate.

---

## Riepilogo per punto

| Punto | Stato |
|-------|--------|
| Frontend: schermata/liste chiamate, CallScreen, CallService | **Non esiste** |
| Frontend: tab Chiamate (contenuto dedicato) | **Placeholder/stub** (tab c’è, contenuto no) |
| Frontend: pulsanti 📞 e 📹 in chat | **Placeholder/stub** (solo SnackBar "coming soon") |
| Frontend: pacchetti WebRTC/chiamate in pubspec | **Non esiste** |
| Backend: modelli Call, CallParticipant, ICEServer | **Implementato** |
| Backend: API REST (log, detail, ice-servers, missed-count) | **Implementato** |
| Backend: WebSocket signaling (offer/answer/ice/accept/reject/end) | **Implementato** |
| Backend: notifiche incoming/missed call e push | **Implementato** |

---

## Cosa manca per avere chiamate end-to-end

1. **Flutter:** SDK/package WebRTC (es. `flutter_webrtc`) e eventuale gestione VoIP (CallKit/ConnectionService).
2. **Flutter:** servizio che apre WebSocket `ws/calls/`, gestisce azioni (initiate, accept, reject, offer, answer, ice_candidate, end) e aggiorna UI.
3. **Flutter:** schermata chiamata in corso (locale/remoto, mute, video on/off, speaker, end) e schermata chiamata in arrivo (accept/reject).
4. **Flutter:** tab Chiamate con lista cronologia (chiamate API `GET /api/calls/log/`).
5. **Flutter:** dai pulsanti 📞/📹 in chat: avvio chiamata (initiate_call su WebSocket + navigazione a schermata chiamata).
6. **Backend:** già pronto (modelli, API, WebSocket, notifiche); eventuale TURN server configurato in `ICEServer` per NAT/firewall.
