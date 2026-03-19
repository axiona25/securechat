# Analisi log iOS CallKit/WebRTC audio — AXPHONE SecureChat

Usare questo schema dopo un test di chiamata incoming da PushKit con `audioSessionActive=false` e patch applicate.

## 1. Timeline compatta (un solo callId)

Incollare i log in ordine e estrarre solo le righe per **un callId**:

| # | Timestamp / ordine | Evento | callId |
|---|--------------------|--------|--------|
| 1 | | ACTION_CALL_INCOMING | |
| 2 | | ACTION_CALL_ACCEPT | |
| 3 | | [NATIVE-AUDIO] didActivate state useManualAudio=... | |
| 4 | | [CallService.iOS-CallKit] _onCallOffer entry | |
| 5 | | [CallService.iOS-CallKit] _onCallOffer after answer | |
| 6 | | [CallService.iOS-CallKit] _onCallAnswer after setRemoteDescription | |
| 7 | | [CallService.iOS-CallKit] onTrack | |
| 8 | | [CallService.iOS-CallKit] onIceConnectionState | |

---

## 2. Tabella stati PeerConnection (dai log Dart)

Dalle righe `[CallService.iOS-CallKit] ... callId=... iceConnectionState=...`:

| Campo | Valore (true/false o stato) |
|-------|-----------------------------|
| remoteDescription | |
| localDescription | |
| iceConnectionState (ultimo visto) | |
| connectionState (ultimo visto) | |
| signalingState (ultimo visto) | |
| onTrack arrivato | sì / no |

---

## 3. Errori audio nativi (cercare in console Xcode)

Cercare e riportare eventuali righe contenenti:

- `SessionCore`
- `AVAudioSession`
- `AURemoteIO`
- `ATAudioSessionPropertyManager`
- `AUIOClient_StartIO`
- `NSOSStatusErrorDomain`
- `error -50` / `error 6` / `error 2`

---

## 4. Regole per il verdetto

- **"Problema principalmente audio route/session"** se:
  - onTrack è arrivato, iceConnectionState è connected/completed, connectionState connected
  - E compaiono errori SessionCore / AVAudioSession / AURemoteIO / NSOSStatus
  - Oppure didActivate non mostra category/mode/route coerenti con voiceChat

- **"Problema principalmente media/ICE"** se:
  - onTrack non arriva O iceConnectionState resta checking/failed/disconnected
  - O remoteDescription/localDescription restano false quando dovrebbero essere true
  - E non ci sono (o sono secondari) errori audio nativi

- **"Misto"** se entrambi: indicare il fattore dominante.

---

## 5. Patch proposta (da compilare dopo verdetto)

- Se **audio route/session**: patch minima su AVAudioSession/RTCAudioSession/route, senza TURN/STUN.
- Se **media/ICE**: patch minima su ICE/candidati/offer-answer, senza toccare CallKit/setCallConnected.

---

## Esempio compilato (da sostituire con log reali)

```
1. Timeline compatta
   callId: abc-123
   1. ACTION_CALL_INCOMING
   2. ACTION_CALL_ACCEPT
   3. didActivate state useManualAudio=true isAudioEnabled=true category=AVAudioSessionCategoryPlayAndRecord mode=AVAudioSessionModeVoiceChat route=Receiver
   4. _onCallOffer entry
   5. _onCallOffer after answer remoteDescription=true localDescription=true
   6. _onCallAnswer — (caller only)
   7. onTrack callId=abc-123
   8. onIceConnectionState RTCIceConnectionStateConnected

2. Tabella stati PC
   remoteDescription: true
   localDescription: true
   iceConnectionState: RTCIceConnectionStateConnected
   connectionState: RTCPeerConnectionStateConnected
   signalingState: RTCSignalingStateStable
   onTrack arrivato: sì

3. Errori audio: SessionCore.mm:517 Failed to set properties error -50

4. Verdetto: Problema principalmente audio route/session

5. Diff proposto: ...
```
