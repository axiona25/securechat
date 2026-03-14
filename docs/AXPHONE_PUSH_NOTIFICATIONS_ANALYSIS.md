# Analisi server notifiche push proprietario AXPHONE

Documento generato dall'analisi del progetto **AXPHONE** (`/Users/r.amoroso/Documents/Cursor/AXPHONE`) per integrare la soluzione push in **SecureChat** (206.189.59.87).

---

## 1. Server-side (backend)

### 1.1 File/modulo che gestisce l'invio delle notifiche

- **Servizio notify (standalone FastAPI):** `server/securevox_notify.py`  
  È un'applicazione FastAPI separata dal backend Django, in ascolto sulla porta **8002**.
- **Invio da Django verso il notify:**  
  `server/src/notifications/tasks.py` — funzioni `send_internal_notification()` e task Celery `send_notification()` che fanno `POST` a `{NOTIFICATION_SERVICE_URL}/send`.

Il flusso tipico è:
1. Il backend Django (o un task Celery) crea una voce in `NotificationQueue` e/o chiama `send_internal_notification()`.
2. `send_internal_notification()` fa una richiesta HTTP `POST` a `{NOTIFY_BASE_URL}/send` (es. `http://securevox-notify:8002/send`).
3. Il server **securevox_notify** riceve la richiesta su `/send`, risolve i device per `recipient_id` (user_id), poi invia via **WebSocket** (se connesso) e/o **APNs** (iOS) e/o **FCM** (Android).

### 1.2 Protocollo usato

- **APNs diretto (iOS):** sì, tramite libreria **apns2** (HTTP/2 verso api.sandbox.push.apple.com o api.push.apple.com).
- **FCM (Android):** sì, tramite **Firebase Admin SDK** (`firebase_admin`, `messaging`).
- **WebSocket:** il notify server espone un WebSocket `ws://host:8002/ws/{device_token}`. Se il client ha una connessione WebSocket aperta, le notifiche vengono inviate in tempo reale su quel canale; altrimenti si usa APNs/FCM (e in fallback polling).
- **Long polling:** endpoint `GET /poll/{device_token}` per recuperare notifiche in coda quando non c’è WebSocket.

Quindi: **APNs diretto** + **FCM** + **WebSocket** + **polling** come fallback.

### 1.3 Registrazione device token

- **Dove:** il notify server gestisce la registrazione in `securevox_notify.py` con l’endpoint **POST /register**.
- **Chi chiama /register:**
  - **Client Flutter:** sia `CustomPushNotificationService` sia `UnifiedRealtimeService` chiamano direttamente `{notifyUrl}/register` (es. `https://www.axphone.it/register`) con payload JSON (device_token, user_id, platform, apns_token/fcm_token, ecc.).
  - **Backend Django (opzionale):** `server/src/api/views.py` → `register_device()`; l’utente autenticato chiama **POST /api/devices/register/** con gli stessi dati; la view fa poi una `POST` al notify server su `{NOTIFY_SERVER_URL}/register` (senza header `X-Notify-Service-Key` nel codice visto; se il notify richiede la service key, va aggiunta in backend).
- **Validazione lato notify:** per iOS è obbligatorio `apns_token`; per Android `fcm_token`. Il notify salva/aggiorna in memoria e su PostgreSQL (tabella `notify_devices`).

### 1.4 Autenticazione server verso Apple APNs

- **Metodo:** **Token-based (chiave .p8)**, non certificato .p12.
- **Libreria:** `apns2` con `TokenCredentials(auth_key_path=..., auth_key_id=..., team_id=...)`.
- **Variabili d’ambiente:**
  - `APNS_AUTH_KEY_PATH`: path assoluto al file **.p8** (Auth Key da Apple Developer).
  - `APNS_KEY_ID`: Key ID della chiave.
  - `APNS_TEAM_ID`: Team ID.
  - `APNS_TOPIC` (o `APNS_BUNDLE_ID`): bundle ID app (topic APNs).
  - `APNS_USE_SANDBOX`: `true` per sandbox, `false` per production.
  - Opzionali: `APNS_USE_ALTERNATIVE_PORT`, `APNS_DEFAULT_SOUND`.

Se `APNS_AUTH_KEY_PATH`, `APNS_KEY_ID` o `APNS_TEAM_ID` mancano, APNs viene disabilitato (log e nessun invio).

### 1.5 API endpoint esposti dal notify server

Tutti su base URL `http(s)://host:8002` (o stesso host con nginx che fa proxy):

| Metodo | Path | Descrizione |
|--------|------|-------------|
| POST   | /register | Registra dispositivo (device_token, user_id, platform, apns_token/fcm_token, app_version, device_id, apns_topic, apns_environment) |
| POST   | /unregister | Disattiva dispositivo (user_id + device_token o apns_token o fcm_token) |
| POST   | /send | Invia notifica (recipient_id, title, body, data, sender_id, timestamp, notification_type; opzionale encrypted + encrypted_payload) |
| GET    | /poll/{device_token} | Polling notifiche per device |
| GET    | /health | Health check |
| GET    | /metrics | Metriche Prometheus (stub) |
| GET    | / | Root con lista endpoint |
| POST   | /cleanup | Cleanup dispositivi inattivi (richiede X-Notify-Service-Key se NOTIFY_SERVICE_KEY è impostato) |
| POST   | /badge-sync | Sincronizzazione badge |
| POST   | /call/start, /call/answer/{call_id}, /call/reject/{call_id}, /call/end/{call_id} | Chiamate |
| POST   | /call/group/start, /call/group/join/{call_id} | Chiamate di gruppo |
| GET    | /websocket/status/{user_id} | Stato WebSocket per user |
| GET    | /devices | Elenco device (debug) |
| POST   | /devices/prune | Prune device |
| POST   | /typing/start, /typing/stop | Typing indicator |
| GET    | /notifications/{user_id} | Notifiche per user (debug) |
| WebSocket | /ws/{device_token} | Connessione real-time notifiche |

Protezione: `verify_service_key(request)` su `/register`, `/unregister`, `/send`, `/cleanup`. Legge `X-Notify-Service-Key` (o `X-Service-Key`); se `NOTIFY_SERVICE_KEY` è impostato e la chiave non coincide → 401. Se `NOTIFY_SERVICE_KEY` è vuoto, la verifica viene saltata (così il client può chiamare `/register` senza chiave).

### 1.6 Modello dati device token (database)

Il notify server **non** usa Django ORM per i device: usa **PostgreSQL** con una tabella gestita a mano.

**Tabella:** `notify_devices` (creata in `init_database()` in `securevox_notify.py`).

```sql
CREATE TABLE IF NOT EXISTS notify_devices (
    device_token VARCHAR(255) PRIMARY KEY,
    user_id VARCHAR(255) NOT NULL,
    platform VARCHAR(50) NOT NULL,
    app_version VARCHAR(50) NOT NULL,
    last_seen DOUBLE PRECISION NOT NULL,
    is_online BOOLEAN NOT NULL DEFAULT TRUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    apns_token VARCHAR(255),
    apns_topic VARCHAR(255),
    apns_environment VARCHAR(50),
    fcm_token VARCHAR(255),
    device_id VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Indici (da codice):
- `idx_notify_devices_user_id`
- `idx_notify_devices_unique_apns_token` (UNIQUE WHERE apns_token IS NOT NULL AND apns_token <> '')
- `idx_notify_devices_unique_fcm_token` (UNIQUE WHERE fcm_token IS NOT NULL AND fcm_token <> '')
- `idx_notify_devices_user_platform`
- `idx_notify_devices_user_device_id` (UNIQUE WHERE device_id IS NOT NULL AND device_id <> '')

In memoria il notify mantiene anche:
- `devices: Dict[str, Device]` (device_token → Device)
- `user_to_devices: Dict[str, Set[str]]` (user_id → set di device_token)
- `device_to_user: Dict[str, str]` (device_token → user_id)

Il modello Django `NotificationQueue` / `NotificationLog` in `server/src/notifications/models.py` è usato dal **backend Django** per accodare le notifiche e tracciare l’invio; il notify server non scrive su quelle tabelle, riceve solo HTTP POST su `/send`.

---

## 2. Client-side (Flutter / iOS)

### 2.1 Registrazione al server notifiche

- **CustomPushNotificationService** (`lib/services/custom_push_notification_service.dart`):
  - Genera o recupera un `device_token` (es. `securevox_ios_$timestamp`) e lo salva in `SharedPreferences` con chiave `securevox_device_token`.
  - Legge `user_id` da `UserService.getCurrentUserIdSync()`.
  - Su iOS ottiene `apns_token`, `apns_environment`, `apns_topic` da **ApnsBridgeService** (bridge nativo).
  - Invia **POST** a `ApiConfig.notifyUrl + '/register'` con body JSON: `device_token`, `user_id`, `platform`, `app_version`, e se iOS: `apns_token`, `apns_environment`, `apns_topic`.
- **UnifiedRealtimeService** (`lib/services/unified_realtime_service.dart`):
  - Stesso `device_token` (stessa chiave `securevox_device_token`).
  - Chiama `notifyServerUrl/register` (dove `notifyServerUrl = ApiConfig.notifyUrl`) con payload analogo, includendo `fcm_token` su Android e `apns_token` su iOS.
  - Si sottoscrive agli aggiornamenti del token APNs e ri-chiama la registrazione quando il token cambia.

Entrambi chiamano quindi **direttamente** l’URL del notify (es. `https://www.axphone.it/register`), che in AXPHONE è lo stesso host con nginx che instrada `/register` al container notify.

### 2.2 Come riceve le notifiche

- **In foreground / con WebSocket:**  
  Il client apre un WebSocket a `wss://{notifyUrl}/ws/{device_token}`. Il notify invia messaggi JSON (type: `notification`, `call`, `call_status`, `typing_start`/`typing_stop`, ecc.). Il client li gestisce in `_handleWebSocketMessage` e li espone su uno stream (es. `messageStream` in `CustomPushNotificationService`).
- **In background / app chiusa (iOS):**  
  Il notify invia tramite **APNs**. Il dispositivo riceve la notifica tramite **APNs nativo**; l’app può gestire il tap e il payload in `ApnsBridgeService` / AppDelegate (e eventuale `onDidReceiveNotificationResponse` in `NotificationManagerService`).
- **Fallback senza WebSocket:**  
  Polling periodico su `GET {notifyUrl}/poll/{device_token}` (es. ogni 5 secondi in `CustomPushNotificationService`).

Quindi: **WebSocket** quando l’app è connessa, **APNs nativo** quando è in background/terminated, **polling** come fallback.

### 2.3 File Dart coinvolti

| File | Ruolo |
|------|--------|
| `lib/services/custom_push_notification_service.dart` | Registrazione notify, WebSocket, polling, invio notifiche/call; stream messaggi |
| `lib/services/notification_manager_service.dart` | Permessi, notifiche locali, badge, toast in-app, suoni |
| `lib/services/unified_realtime_service.dart` | Registrazione device (notify + APNs/FCM), stream eventi real-time, chiamate, typing |
| `lib/services/apns_bridge_service.dart` | Bridge con nativo iOS: permessi, token APNs, environment, topic |
| `lib/config/api_config.dart` | `notifyUrl`, `backendUrl`, `apiUrl` (base URL per notify e API) |

Altri riferimenti: `notification_preferences_service.dart`, `realtime_call_notifications.dart`, `call_notification_service.dart`, `typing_indicator_service.dart`, integrazioni in `main.dart` e schermate (es. `home_screen`, `chat_detail_screen`).

---

## 3. Configurazione e deployment

### 3.1 Dipendenze Python (notify server)

File: `server/notification_requirements.txt`

```
fastapi>=0.104.1
uvicorn[standard]>=0.24.0
websockets>=12.0
pydantic>=2.5.0
python-multipart>=0.0.6
aiohttp>=3.9.0
apns2>=0.7.2
```

Per FCM (Android) serve anche `firebase-admin` (non in questo file; probabilmente in `requirements.txt` principale del server).  
Nel `Dockerfile.production` del server vengono installati: `fastapi`, `uvicorn[standard]`, `websockets`, `pydantic`, `python-multipart`, `aiohttp`, `apns2`.

Altre dipendenze usate da `securevox_notify.py`: `psycopg` (PostgreSQL), `python-dotenv`, `uvicorn`.

### 3.2 Docker (docker-compose)

Dal file `docker-compose.digitalocean-50users.yml`:

**Servizio notify-server:**

```yaml
  notify-server:
    build:
      context: ./server
      dockerfile: Dockerfile.production
    container_name: securevox-notify
    env_file:
      - .env
    command: sh -c "cd /app && /opt/venv/bin/python securevox_notify.py"
    environment:
      - DJANGO_SETTINGS_MODULE=src.settings
      - SECRET_KEY=${SECRET_KEY:-${DJANGO_SECRET_KEY}}
      - DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
      - DATABASE_URL=postgresql://securevox:change_me_db@securevox-postgres:5432/securevox_db
      - REDIS_URL=redis://redis:6379/2
      - FIREBASE_SERVICE_ACCOUNT=${FIREBASE_SERVICE_ACCOUNT:-}
      - APNS_KEY=${APNS_KEY:-}
      - APNS_KEY_ID=${APNS_KEY_ID:-}
      - APNS_TEAM_ID=${APNS_TEAM_ID:-}
      - APNS_TOPIC=${APNS_TOPIC:-}
      - APNS_USE_SANDBOX=${APNS_USE_SANDBOX:-true}
      - BACKEND_URL=http://django-backend:8000
      - PYTHONPATH=/app/src
    volumes:
      - ./logs:/app/logs
    ports:
      - "127.0.0.1:8002:8002"
    depends_on:
      - redis
      - django-backend
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "/opt/venv/bin/python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8002/health').read()\" || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

**Backend Django** deve avere:
- `NOTIFY_BASE_URL=http://securevox-notify:8002`
- `NOTIFY_SERVER_URL=http://securevox-notify:8002`

Nel codice del notify, per APNs viene usato **APNS_AUTH_KEY_PATH** (path al file .p8), non `APNS_KEY`; quindi o in `.env` si imposta `APNS_AUTH_KEY_PATH` (path nel container, es. `/app/secrets/AuthKey_xxx.p8`), oppure il compose va esteso con una variabile e un volume per il file .p8.

### 3.3 Variabili d’ambiente notevoli

| Variabile | Dove | Descrizione |
|-----------|------|-------------|
| DATABASE_URL | notify | PostgreSQL (stesso DB può essere condiviso con Django); obbligatorio per il notify |
| NOTIFY_SERVICE_KEY | notify | Chiave condivisa; se impostata, richiesta in header X-Notify-Service-Key su /register, /unregister, /send, /cleanup |
| APNS_AUTH_KEY_PATH | notify | Path al file .p8 (Auth Key Apple) |
| APNS_KEY_ID | notify | Key ID della chiave APNs |
| APNS_TEAM_ID | notify | Team ID Apple |
| APNS_TOPIC / APNS_BUNDLE_ID | notify | Bundle ID (topic) |
| APNS_USE_SANDBOX | notify | true/false |
| FCM_CREDENTIALS_PATH | notify | Path al JSON del service account Firebase (per FCM) |
| BACKEND_BASE_URL | notify | Base URL del backend Django (per badge, check is-read, ecc.) |

### 3.4 Nginx – routing verso il notify

Dal file `nginx/nginx.digitalocean.conf`:

- Upstream: `notify_server` → `securevox-notify:8002`.
- Location:
  - `location /ws/` → `proxy_pass http://notify_server` (WebSocket).
  - `location ~ ^/poll/` → `proxy_pass http://notify_server`.
  - `location ~ ^/(send|devices|health|register|unregister|badge-sync)$` → `proxy_pass http://notify_server`.

Quindi sullo stesso host (es. `https://www.axphone.it`) i path `/register`, `/send`, `/unregister`, `/poll/...`, `/ws/...` vengono inviati al container notify.

### 3.5 Certificati / chiavi necessarie

- **Apple APNs:**  
  File **.p8** (Auth Key) da Apple Developer; nel container va esposto come file e `APNS_AUTH_KEY_PATH` deve puntare a quel path.  
  Nessun certificato .p12 nel codice analizzato.
- **FCM (Android):**  
  File JSON del **service account** Firebase; esposto nel container e `FCM_CREDENTIALS_PATH` punta a quel file.
- **HTTPS:**  
  Gestito da nginx (es. Let’s Encrypt); il notify in ascolto su 8002 può restare in HTTP in rete interna.

---

## 4. Contenuto file chiave (riferimento)

### 4.1 Backend Django – registrazione device (proxy al notify)

`server/src/api/views.py` (estratti):

```python
@api_view(['POST'])
@permission_classes([IsAuthenticated])
def register_device(request):
    """Registra o aggiorna un dispositivo per le notifiche push (APNs/FCM)"""
    try:
        data = request.data
        device_token = data.get('device_token')
        platform = data.get('platform', '').lower()
        app_version = data.get('app_version', '1.0.0')
        apns_token = data.get('apns_token')
        apns_topic = data.get('apns_topic')
        apns_environment = data.get('apns_environment')
        fcm_token = data.get('fcm_token')
        device_id = data.get('device_id')

        if not device_token:
            return Response({"error": "device_token is required"}, status=status.HTTP_400_BAD_REQUEST)
        if not platform or platform not in ['ios', 'android']:
            return Response({"error": "platform must be 'ios' or 'android'"}, status=status.HTTP_400_BAD_REQUEST)
        if platform == 'ios' and not apns_token:
            return Response({"error": "apns_token is required for iOS devices"}, status=status.HTTP_400_BAD_REQUEST)
        if platform == 'android' and not fcm_token:
            return Response({"error": "fcm_token is required for Android devices"}, status=status.HTTP_400_BAD_REQUEST)

        user_id = str(request.user.id)
        notify_server_url = os.getenv('NOTIFY_SERVER_URL', 'http://localhost:8002')
        payload = {
            'device_token': device_token,
            'user_id': user_id,
            'platform': platform,
            'app_version': app_version,
        }
        if apns_token:
            payload['apns_token'] = apns_token
        if apns_topic:
            payload['apns_topic'] = apns_topic
        if apns_environment:
            payload['apns_environment'] = apns_environment
        if fcm_token:
            payload['fcm_token'] = fcm_token
        if device_id:
            payload['device_id'] = device_id

        response = requests.post(
            f"{notify_server_url}/register",
            json=payload,
            timeout=5.0
        )
        response.raise_for_status()
        return Response({
            "status": "success",
            "message": "Device registered successfully",
            "device_token": device_token,
            "platform": platform
        })
    except requests.exceptions.RequestException as e:
        logger.error(f"Error registering device with notify server: {e}")
        return Response(
            {"error": "Failed to register device with notify server"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
```

Se sul notify è impostato `NOTIFY_SERVICE_KEY`, qui andrebbe aggiunto l’header `X-Notify-Service-Key` nella richiesta a `notify_server_url/register`.

### 4.2 Invio notifiche da Django al notify

`server/src/notifications/tasks.py` (estratti):

```python
NOTIFICATION_SERVICE_URL = os.getenv("NOTIFY_BASE_URL", os.getenv("NOTIFY_SERVER_URL", "http://securevox-notify:8002")).rstrip("/")

def send_internal_notification(user_id, notification_type, payload, priority='normal', ...):
    # ...
    headers = {'Content-Type': 'application/json'}
    if request_id:
        headers['X-Request-ID'] = request_id
    if correlation_id:
        headers['X-Correlation-ID'] = correlation_id
    # Se il backend usa NOTIFY_SERVICE_KEY, va aggiunto qui:
    # if os.getenv('SERVICE_AUTH_KEY'):
    #     headers['X-Notify-Service-Key'] = os.getenv('SERVICE_AUTH_KEY')

    response = requests.post(
        f"{NOTIFICATION_SERVICE_URL}/send",
        json=notification_data,
        headers=headers,
        timeout=10
    )
```

Nel progetto AXPHONE il notify legge `NOTIFY_SERVICE_KEY` in `SERVICE_AUTH_KEY`; il backend Django potrebbe usare la stessa chiave (es. `SERVICE_AUTH_KEY` o `NOTIFY_SERVICE_KEY`) e inviarla in `X-Notify-Service-Key` nelle chiamate a `/send` (e `/cleanup`).

### 4.3 Notify – verifica service key e avvio

`server/securevox_notify.py` (estratti):

```python
SERVICE_AUTH_KEY = os.getenv("NOTIFY_SERVICE_KEY", "").strip()

def verify_service_key(request: Request) -> None:
    if not SERVICE_AUTH_KEY:
        return
    provided_key = (
        request.headers.get("X-Notify-Service-Key")
        or request.headers.get("X-Service-Key")
    )
    normalized = (provided_key or "").strip()
    if normalized != SERVICE_AUTH_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized: invalid service key")
```

Avvio server (fine file):

```python
if __name__ == "__main__":
    bootstrap()  # init_database, load_devices_from_db, init_apns_client, init_fcm
    uvicorn.run(
        "securevox_notify:app",
        host="0.0.0.0",
        port=8002,
        reload=not is_production,
        log_level="info"
    )
```

### 4.4 Modelli Django notifiche (coda e log)

`server/src/notifications/models.py`:

```python
class NotificationQueue(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='notifications', null=True, blank=True)
    notification_type = models.CharField(max_length=20, choices=[
        ('message', 'Message'),
        ('call', 'Call'),
        ('remote_wipe', 'Remote Wipe'),
        ('key_rotation', 'Key Rotation'),
    ])
    payload = models.JSONField(default=dict)
    priority = models.CharField(max_length=10, default='normal', ...)
    created_at = models.DateTimeField(auto_now_add=True)
    scheduled_at = models.DateTimeField(default=timezone.now)
    sent_at = models.DateTimeField(null=True, blank=True)
    failed_at = models.DateTimeField(null=True, blank=True)
    retry_count = models.PositiveIntegerField(default=0)
    max_retries = models.PositiveIntegerField(default=3)

class NotificationLog(models.Model):
    notification = models.OneToOneField(NotificationQueue, on_delete=models.CASCADE, related_name='log')
    fcm_message_id = models.CharField(max_length=255, null=True, blank=True)
    apns_message_id = models.CharField(max_length=255, null=True, blank=True)
    response_status = models.CharField(max_length=10, choices=[('success', 'Success'), ('failed', 'Failed'), ('retry', 'Retry')])
    response_data = models.JSONField(null=True, blank=True)
    sent_at = models.DateTimeField(auto_now_add=True)
```

### 4.5 Client – registrazione e WebSocket (CustomPushNotificationService)

`mobile/securevox_app/lib/services/custom_push_notification_service.dart` (estratti):

- `_notificationServerUrl` = `ApiConfig.notifyUrl`.
- `_registerDevice()`:  
  `POST $_notificationServerUrl/register` con body:  
  `device_token`, `user_id`, `platform`, `app_version`, e su iOS: `apns_token`, `apns_environment`, `apns_topic`.
- WebSocket:  
  `wsUrl = '$wsBase/ws/$_deviceToken'` (dove `wsBase` è notifyUrl in wss/ws).  
  Messaggi: `notification`, `call`, `call_status`, `typing_start`/`typing_stop`, `pong`.
- Polling:  
  `GET $_notificationServerUrl/poll/$_deviceToken` a intervalli (es. 5 s) se WebSocket non è connesso.

---

## 5. Integrazione in SecureChat (206.189.59.87)

Sintesi operativa:

1. **Deploy del notify server**  
   - Copiare/adattare `server/securevox_notify.py` e `server/notification_requirements.txt` (e le parti del Dockerfile che installano le dipendenze notify).  
   - Aggiungere un servizio `notify-server` nel docker-compose (stesso schema di AXPHONE: porta 8002, `DATABASE_URL`, `APNS_*`, `FCM_CREDENTIALS_PATH`, `BACKEND_BASE_URL`, `NOTIFY_SERVICE_KEY`).  
   - Creare la tabella `notify_devices` sullo stesso PostgreSQL (o DB dedicato) eseguendo le stesse `CREATE TABLE` e `CREATE INDEX` usate in `init_database()`.

2. **Backend (SecureChat)**  
   - Esporre endpoint `POST /api/devices/register/` e `POST /api/devices/unregister/` che inoltrano a `http://securevox-notify:8002/register` e `/unregister` (aggiungendo `X-Notify-Service-Key` se usi `NOTIFY_SERVICE_KEY`).  
   - Per l’invio notifiche: chiamare `POST http://securevox-notify:8002/send` con lo stesso schema di payload (recipient_id, title, body, data, sender_id, timestamp, notification_type); oppure riusare il pattern con `NotificationQueue` + task Celery che chiama `send_internal_notification`/`/send`.

3. **Nginx**  
   - Aggiungere upstream `notify_server` → `securevox-notify:8002` e le location per `/ws/`, `/poll/`, `/register`, `/unregister`, `/send`, `/health` (e altri endpoint che servono).

4. **Client Flutter (SecureChat)**  
   - Introdurre un modulo equivalente a `CustomPushNotificationService` / `UnifiedRealtimeService` che:  
     - usa un `notifyUrl` (es. `https://206.189.59.87` o il dominio reale) per `/register`, `/ws/`, `/poll/`.  
     - su iOS usa `ApnsBridgeService` (o equivalente) e invia `apns_token`, `apns_environment`, `apns_topic` in registrazione.  
     - si connette al WebSocket e/o fa polling, e gestisce gli eventi come in AXPHONE.

5. **Segreti**  
   - File .p8 (APNs) e JSON FCM nel server, con `APNS_AUTH_KEY_PATH` e `FCM_CREDENTIALS_PATH` impostati nel container (volume o secret).

Con queste parti si replica il comportamento del server di notifiche push proprietario AXPHONE su SecureChat (206.189.59.87).
