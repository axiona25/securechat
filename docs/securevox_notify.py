#!/usr/bin/env python3
"""
SecureVOX Notify - Servizio di notifiche push personalizzato con E2EE
Gestisce messaggi, notifiche, chiamate e videochiamate per iOS, Android e Web
Sostituisce completamente Firebase per le notifiche real-time
NOTA: Le notifiche sono CIFRATE end-to-end per proteggere i metadati
"""

# 🔧 PATCH Python 3.12: Monkey patch per compatibilità collections
import collections
import collections.abc
# Aggiungi Iterable, Mapping, MutableSet, MutableMapping a collections per retrocompatibilità
if not hasattr(collections, 'Iterable'):
    collections.Iterable = collections.abc.Iterable
if not hasattr(collections, 'Mapping'):
    collections.Mapping = collections.abc.Mapping
if not hasattr(collections, 'MutableSet'):
    collections.MutableSet = collections.abc.MutableSet
if not hasattr(collections, 'MutableMapping'):
    collections.MutableMapping = collections.abc.MutableMapping

import asyncio
import json
import os
import time
import psycopg
from psycopg.conninfo import conninfo_to_dict
from datetime import datetime
from typing import Dict, List, Optional, Set
from threading import Lock
from dataclasses import dataclass, asdict, field
from enum import Enum
from pathlib import Path
import traceback
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn
from dotenv import load_dotenv
import uuid
import hashlib

try:
    from apns2.client import APNsClient, NotificationPriority
    from apns2.credentials import TokenCredentials
    from apns2.payload import Payload, PayloadAlert
    from apns2.errors import BadDeviceToken, Unregistered
    APNS_LIB_AVAILABLE = True
except ImportError:
    APNsClient = None  # type: ignore
    TokenCredentials = None  # type: ignore
    Payload = None  # type: ignore
    PayloadAlert = None  # type: ignore
    NotificationPriority = None  # type: ignore
    BadDeviceToken = None  # type: ignore
    Unregistered = None  # type: ignore
    APNS_LIB_AVAILABLE = False

try:
    import firebase_admin
    from firebase_admin import credentials, messaging
    FCM_LIB_AVAILABLE = True
except ImportError:
    firebase_admin = None  # type: ignore
    credentials = None  # type: ignore
    messaging = None  # type: ignore
    FCM_LIB_AVAILABLE = False

# Tipi di notifiche supportate
class NotificationType(str, Enum):
    MESSAGE = "message"
    MESSAGE_UPDATED = "message_updated"
    MESSAGE_DELETED = "message_deleted"
    CALL = "call"
    VIDEO_CALL = "video_call"
    GROUP_CALL = "group_call"
    GROUP_VIDEO_CALL = "group_video_call"
    SYSTEM = "system"
    FRIEND_REQUEST = "friend_request"
    CHAT_INVITE = "chat_invite"
    CHAT_DELETED = "chat_deleted"
    CHAT_MEMBERSHIP_UPDATE = "chat_membership_update"
    BADGE_SYNC = "badge_sync"

# Stati delle chiamate
class CallStatus(str, Enum):
    INCOMING = "incoming"
    RINGING = "ringing"
    ANSWERED = "answered"
    REJECTED = "rejected"
    ENDED = "ended"
    MISSED = "missed"

# Modelli per le notifiche
@dataclass
class Device:
    device_token: str
    user_id: str
    platform: str
    app_version: str
    last_seen: float
    is_online: bool = True
    is_active: bool = True  # T0.2: Device attivo (per unregister)
    apns_token: Optional[str] = None
    apns_topic: Optional[str] = None
    apns_environment: Optional[str] = None
    fcm_token: Optional[str] = None  # FCM token per Android
    device_id: Optional[str] = None  # Device ID univoco per identificare dispositivi
    websocket: Optional[WebSocket] = None
    ws_conn_id: Optional[str] = None  # OBSERVABILITY: WebSocket connection ID
    device_id_hash: Optional[str] = None  # OBSERVABILITY: Opaque device identifier (SHA256[:16])

@dataclass
class Notification:
    id: str
    recipient_id: str
    title: str
    body: str
    data: Dict
    sender_id: str
    timestamp: float
    notification_type: NotificationType
    delivered: bool = False
    delivered_to_devices: Set[str] = field(default_factory=set)  # Set di device_token ai quali la notifica è stata consegnata
    call_status: Optional[CallStatus] = None
    call_duration: Optional[int] = None  # in secondi per le chiamate

class DeviceRegistration(BaseModel):
    device_token: str
    user_id: str
    platform: str
    app_version: str
    apns_token: Optional[str] = None
    apns_topic: Optional[str] = None
    apns_environment: Optional[str] = None
    fcm_token: Optional[str] = None  # FCM token per Android
    device_id: Optional[str] = None  # Device ID univoco

class DeviceUnregister(BaseModel):
    user_id: str
    platform: Optional[str] = None
    device_token: Optional[str] = None
    apns_token: Optional[str] = None
    fcm_token: Optional[str] = None

class NotificationRequest(BaseModel):
    recipient_id: str
    title: str
    body: str
    data: Dict
    sender_id: str
    timestamp: str
    notification_type: NotificationType = NotificationType.MESSAGE
    # E2EE: Campi per notifiche cifrate
    encrypted: bool = False  # Se True, usa encrypted_payload invece di title/body
    encrypted_payload: Optional[Dict] = None  # {ciphertext, iv, mac}


class BadgeSyncRequest(BaseModel):
    user_id: str
    total_unread: int
    chat_id: Optional[str] = None
    chat_unread: Optional[int] = None
    read_message_ids: Optional[List[str]] = None
    source: Optional[str] = "system"
    timestamp: Optional[str] = None

class PruneDevicesRequest(BaseModel):
    max_age_days: Optional[float] = None
    remove_without_apns: bool = True
    dry_run: bool = False


class CallRequest(BaseModel):
    recipient_id: str
    sender_id: str
    call_type: str  # "audio" o "video"
    is_group: bool = False
    group_members: Optional[List[str]] = None
    call_id: str
    auth_token: Optional[str] = None

class GroupCallRequest(BaseModel):
    sender_id: str
    group_members: List[str]
    call_type: str  # "audio" o "video"
    room_name: Optional[str] = "Group Call"
    max_participants: Optional[int] = 10
    call_id: Optional[str] = None
    auth_token: Optional[str] = None

class CallResponse(BaseModel):
    call_id: str
    status: CallStatus
    message: str

class NotificationResponse(BaseModel):
    notifications: List[Dict]
    status: str

# Inizializza FastAPI
app = FastAPI(title="SecureVOX Notify", version="1.0.0")

# OBSERVABILITY B2: Metrics stub (riuso/copia dello stub Django)
try:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent / 'src'))
    from observability.metrics import MetricsCollector
    notify_metrics = MetricsCollector()
except ImportError:
    # Fallback: copia minima dello stub
    class MetricsCollector:
        def __init__(self):
            self._counters = {}
            self._lock = Lock()
        def increment_counter(self, name, labels=None, value=1.0):
            with self._lock:
                key = f"{name}{labels or {}}"
                self._counters[key] = self._counters.get(key, 0) + value
        def export_prometheus(self):
            with self._lock:
                lines = ["# OBSERVABILITY: Metrics stub\n"]
                for key, value in self._counters.items():
                    lines.append(f"{key} {value}\n")
                return "".join(lines)
    notify_metrics = MetricsCollector()

@app.get("/metrics")
async def metrics_endpoint():
    """OBSERVABILITY: Endpoint metriche (stub, preparato per Prometheus)"""
    from fastapi.responses import Response
    return Response(
        content=notify_metrics.export_prometheus(),
        media_type='text/plain; version=0.0.4'
    )


def bootstrap_env():
    """Carica le variabili d'ambiente da file .env, se presenti."""
    explicit_path = os.getenv("NOTIFY_ENV_FILE", "").strip()
    candidates = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    candidates.append(Path(".env.notify"))
    candidates.append(Path(".env"))

    for candidate in candidates:
        if candidate.is_file():
            load_dotenv(dotenv_path=candidate)
            print(f"🗂️  Caricato file ambiente: {candidate}")
            return

    load_dotenv()


bootstrap_env()

# CORS Configuration - Environment-based
DEBUG = os.getenv('DEBUG', 'False').lower() in ('true', '1', 'yes')
# Debug personalizzato per SecureVOX Notify
NOTIFY_DEBUG = os.getenv("NOTIFY_DEBUG", "false").lower() in ("true", "1", "yes")


def log_debug(message: str, *, force: bool = False):
    """Logga messaggi di debug dettagliati quando abilitato."""
    if NOTIFY_DEBUG or force:
        timestamp = datetime.utcnow().isoformat()
        print(f"🧪[{timestamp}] {message}")

def extract_message_id(data: Dict) -> Optional[str]:
    """Estrae il message_id da un payload notifica, se presente."""
    if not data:
        return None
    message_id = data.get("message_id")
    if message_id:
        return str(message_id)
    nested = data.get("data")
    if isinstance(nested, dict):
        nested_id = nested.get("message_id")
        if nested_id:
            return str(nested_id)
    return None

# CORS per permettere richieste dal frontend
if DEBUG:
    # Development: allow all origins
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    # Production: restrict origins
    allowed_origins = os.getenv('CORS_ALLOWED_ORIGINS', 'http://localhost:8001').split(',')
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allowed_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Content-Type", "Authorization"],
    )

# Storage in memoria (in produzione usare Redis o database)
devices: Dict[str, Device] = {}
notifications: Dict[str, List[Notification]] = {}
active_calls: Dict[str, Dict] = {}  # call_id -> call_data
notification_counter = 0
call_counter = 0

# Mappature per gestire user_id <-> device_token (supporto multi-device)
user_to_devices: Dict[str, Set[str]] = {}  # user_id -> set(device_token)
device_to_user: Dict[str, str] = {}  # device_token -> user_id

# C2-NOTIFY: Cache TTL per dedup call_event: (call_id, event, by_user_id) -> timestamp
# TTL: 60 secondi (cleanup automatico)
_call_event_dedup_cache: Dict[tuple, float] = {}  # (call_id, event, by_user_id) -> timestamp
_CALL_EVENT_DEDUP_TTL_SECONDS = 60

# C4-B: Cache TTL per dedup group_call_event: (room_id, event, by_user_id, target_user_id) -> timestamp
# TTL: 60 secondi (cleanup automatico)
_group_call_event_dedup_cache: Dict[tuple, float] = {}  # (room_id, event, by_user_id, target_user_id) -> timestamp
_GROUP_CALL_EVENT_DEDUP_TTL_SECONDS = 60

# 💾 DATABASE PERSISTENTE PER DISPOSITIVI - PostgreSQL
# Usa DATABASE_URL dall'ambiente, stesso database del backend Django
DATABASE_URL = os.getenv('DATABASE_URL', '').strip()
if not DATABASE_URL:
    raise ValueError("DATABASE_URL deve essere impostato per il server notify")

# 📬 APNs (Apple Push Notification service) configurazione runtime
apns_client: Optional[APNsClient] = None
APNS_ENABLED = False
APNS_TOPIC: Optional[str] = None
APNS_USE_SANDBOX = True
APNS_ALTERNATIVE_PORT = False
APNS_DEFAULT_SOUND = "default"
APNS_LAST_ERROR: Optional[str] = None
APNS_SEND_LOCK = Lock()
APNS_CLIENT_CACHE: Dict[str, APNsClient] = {}
APNS_CLIENT_SETTINGS: Dict[str, Dict[str, Optional[str]]] = {}

# 🔥 FCM (Firebase Cloud Messaging) configurazione runtime
FCM_ENABLED = False
FCM_LAST_ERROR: Optional[str] = None
FCM_SEND_LOCK = Lock()

# Backend API (Django) per conteggio badge
BACKEND_BASE_URL = os.getenv("BACKEND_BASE_URL", "http://localhost:8001/api").rstrip("/")
SERVICE_AUTH_KEY = os.getenv("NOTIFY_SERVICE_KEY", "").strip()
try:
    BACKEND_TIMEOUT = float(os.getenv("BACKEND_SERVICE_TIMEOUT", "5"))
except ValueError:
    BACKEND_TIMEOUT = 5.0


def sanitize_apns_token(token: str) -> str:
    """Normalizza il device token APNs eliminando spazi e simboli <>."""
    return token.replace(" ", "").replace("<", "").replace(">", "").strip()


def normalize_apns_environment(env: Optional[str]) -> str:
    """Normalizza il valore di ambiente APNs."""
    if not env:
        return "sandbox" if APNS_USE_SANDBOX else "production"
    lowered = env.strip().lower()
    if lowered in {"development", "sandbox"}:
        return "sandbox"
    if lowered in {"production", "prod", "release"}:
        return "production"
    return lowered


def init_apns_client(environment: Optional[str] = None, force: bool = False) -> Optional[APNsClient]:
    """Inizializza (o reinizializza) il client APNs basandosi sulle variabili d'ambiente.

    Se vengono gestiti dispositivi con ambienti diversi (sandbox/production) creiamo una cache
    di client separati per evitare mismatch e riutilizzare le connessioni HTTP/2.
    """
    global apns_client, APNS_ENABLED, APNS_TOPIC, APNS_USE_SANDBOX, APNS_ALTERNATIVE_PORT, APNS_DEFAULT_SOUND, APNS_LAST_ERROR
    global APNS_CLIENT_CACHE, APNS_CLIENT_SETTINGS

    if not APNS_LIB_AVAILABLE:
        print("⚠️ APNs non disponibile: installare la dipendenza 'apns2' (pip install apns2)")
        APNS_ENABLED = False
        APNS_LAST_ERROR = "apns2 library missing"
        return None

    key_path = os.getenv("APNS_AUTH_KEY_PATH")
    key_id = os.getenv("APNS_KEY_ID")
    team_id = os.getenv("APNS_TEAM_ID")
    topic = os.getenv("APNS_TOPIC") or os.getenv("APNS_BUNDLE_ID")
    default_use_sandbox = os.getenv("APNS_USE_SANDBOX", "true").lower() in ("true", "1", "yes", "sandbox")
    alternative_port = os.getenv("APNS_USE_ALTERNATIVE_PORT", "false").lower() in ("true", "1", "yes")
    default_sound = os.getenv("APNS_DEFAULT_SOUND", "default")

    requested_environment = normalize_apns_environment(environment)
    use_sandbox = requested_environment != "production"

    cache_key = f"{requested_environment}:{topic}:{key_path}:{key_id}:{team_id}:{int(alternative_port)}"

    if not force and cache_key in APNS_CLIENT_CACHE:
        cached_client = APNS_CLIENT_CACHE[cache_key]
        cached_settings = APNS_CLIENT_SETTINGS.get(cache_key, {})
        apns_client = cached_client
        APNS_ENABLED = True
        APNS_TOPIC = cached_settings.get("topic", topic)
        APNS_USE_SANDBOX = cached_settings.get("use_sandbox", use_sandbox)  # type: ignore
        APNS_ALTERNATIVE_PORT = cached_settings.get("alternative_port", alternative_port)  # type: ignore
        APNS_DEFAULT_SOUND = cached_settings.get("default_sound", default_sound)  # type: ignore
        APNS_LAST_ERROR = None
        return cached_client

    if not topic:
        print("⚠️ APNs disabilitato: impostare APNS_TOPIC (o APNS_BUNDLE_ID) nell'ambiente")
        APNS_ENABLED = False
        APNS_TOPIC = None
        APNS_LAST_ERROR = "missing APNS_TOPIC"
        return None

    if not (key_path and key_id and team_id):
        print("⚠️ APNs disabilitato: mancano APNS_AUTH_KEY_PATH, APNS_KEY_ID o APNS_TEAM_ID")
        APNS_ENABLED = False
        apns_client = None
        APNS_TOPIC = topic
        APNS_LAST_ERROR = "missing APNS credentials"
        return None

    if not os.path.exists(key_path):
        print(f"❌ APNs auth key non trovata: {key_path}")
        APNS_ENABLED = False
        apns_client = None
        APNS_TOPIC = topic
        APNS_LAST_ERROR = f"auth key not found: {key_path}"
        return None

    try:
        credentials = TokenCredentials(auth_key_path=key_path, auth_key_id=key_id, team_id=team_id)
        apns_client = APNsClient(
            credentials,
            use_sandbox=use_sandbox,
            use_alternative_port=alternative_port,
        )
        APNS_ENABLED = True
        APNS_TOPIC = topic
        APNS_USE_SANDBOX = use_sandbox
        APNS_ALTERNATIVE_PORT = alternative_port
        APNS_DEFAULT_SOUND = default_sound
        APNS_LAST_ERROR = None
        print(
            f"📬 APNs client inizializzato: topic={topic}, sandbox={use_sandbox}, alternative_port={alternative_port}"
        )
        APNS_CLIENT_CACHE[cache_key] = apns_client
        APNS_CLIENT_SETTINGS[cache_key] = {
            "topic": APNS_TOPIC,
            "use_sandbox": APNS_USE_SANDBOX,
            "alternative_port": APNS_ALTERNATIVE_PORT,
            "default_sound": APNS_DEFAULT_SOUND,
        }
        return apns_client
    except Exception as exc:  # pragma: no cover
        APNS_ENABLED = False
        apns_client = None
        APNS_TOPIC = topic
        APNS_LAST_ERROR = str(exc)
        print(f"❌ Errore inizializzazione APNs: {exc}")
        return None


def _send_apns_sync(
    client: APNsClient,
    device: Device,
    notification: Notification,
    *,
    attempt: int = 1,
) -> bool:
    """Invia in modo sincrono una notifica APNs. Da chiamare in executor."""
    if not device.apns_token:
        return False

    token = sanitize_apns_token(device.apns_token)
    topic = device.apns_topic or APNS_TOPIC

    if not topic:
        print(f"⚠️ APNs - topic mancante, impossibile notificare {device.user_id}")
        return False

    custom_payload = dict(notification.data or {})
    custom_payload.update(
        {
            "notification_id": notification.id,
            "sender_id": notification.sender_id,
            "notification_type": notification.notification_type.value,
            "timestamp": notification.timestamp,
        }
    )
    custom_payload["apns_environment"] = device.apns_environment or (
        "sandbox" if APNS_USE_SANDBOX else "production"
    )

    sound_value = custom_payload.get("sound") or APNS_DEFAULT_SOUND
    if not isinstance(sound_value, str):
        sound_value = APNS_DEFAULT_SOUND

    badge_value = custom_payload.get("badge")
    if isinstance(badge_value, str):
        try:
            badge_value = int(badge_value)
        except ValueError:
            badge_value = None
    elif isinstance(badge_value, bool):
        badge_value = int(badge_value)
    elif not isinstance(badge_value, int):
        badge_value = None

    alert = PayloadAlert(title=notification.title, body=notification.body)
    payload = Payload(alert=alert, sound=sound_value, badge=badge_value, custom=custom_payload)

    try:
        serialized_payload = json.dumps(payload.dict(), ensure_ascii=False)
    except Exception:
        serialized_payload = str(payload.dict())

    print(
        "📦 APNs - Payload pronto per l'invio: "
        f"title='{notification.title}' body_length={len(notification.body or '')} "
        f"sound='{sound_value}' badge={badge_value} "
        f"custom_keys={list(custom_payload.keys())}"
    )
    print(f"📦 APNs - Payload JSON: {serialized_payload}")

    try:
        with APNS_SEND_LOCK:
            client.send_notification(
                token,
                payload,
                topic=topic,
                priority=NotificationPriority.Immediate,
            )
        print(
            f"📬 APNs push inviato a {device.user_id} (token={token[:10]}..., topic={topic}) "
            "status=200 apns_id=n/a reason=Success"
        )
        return True
    except BadDeviceToken as exc:
        print(f"❌ Errore invio APNs a {device.user_id}: {exc!r}")
        print("   • Il token non è valido per l'ambiente attuale")
        if attempt == 1 and device.apns_environment != "sandbox":
            print("   • Converto il dispositivo a ambiente 'sandbox' e riprovo una volta")
            device.apns_environment = "sandbox"
            save_device_to_db(device)
            cache_key_prod = f"production:{device.apns_topic or APNS_TOPIC}:{os.getenv('APNS_AUTH_KEY_PATH')}:{os.getenv('APNS_KEY_ID')}:{os.getenv('APNS_TEAM_ID')}:{int(APNS_ALTERNATIVE_PORT)}"
            APNS_CLIENT_CACHE.pop(cache_key_prod, None)
            apns_client_sandbox = init_apns_client(environment="sandbox", force=False)
            if apns_client_sandbox:
                return _send_apns_sync(apns_client_sandbox, device, notification, attempt=2)
        return False
    except Unregistered as exc:
        print(f"❌ APNs ha restituito Unregistered per {device.user_id}: {exc!r}")
        print("   • Rimuovo il token APNs dal dispositivo e disattivo device; servirà una nuova registrazione dal client.")
        device.apns_token = None
        device.is_active = False
        save_device_to_db(device)
        return False
    except (BrokenPipeError, ConnectionResetError) as exc:
        print(f"❌ Errore invio APNs a {device.user_id}: {exc!r}")
        print("   • La connessione HTTP/2 con APNs risulta interrotta.")
        if attempt == 1:
            print("   • Reinizializzo il client APNs e ritento l'invio una volta.")
            retry_environment = normalize_apns_environment(
                device.apns_environment
                or ("sandbox" if APNS_USE_SANDBOX else "production")
            )
            refreshed_client = init_apns_client(environment=retry_environment, force=True)
            if refreshed_client:
                return _send_apns_sync(refreshed_client, device, notification, attempt=2)
        return False
    except Exception as exc:  # pragma: no cover
        print(f"❌ Errore invio APNs a {device.user_id}: {exc!r}")
        print(f"   • Tipo eccezione: {type(exc).__name__}")
        stack = traceback.format_exc()
        print(f"   • Stack trace:\n{stack}")
        return False


async def push_via_apns(device: Device, notification: Notification) -> bool:
    """Invia la notifica tramite APNs sfruttando un executor."""
    if not device.apns_token:
        print(f"⚠️ APNs - dispositivo {device.user_id} senza token APNs, notifica saltata")
        return False

    client_environment = (device.apns_environment or "").strip().lower()
    client = init_apns_client(environment=client_environment)
    if not (APNS_ENABLED and client):
        print("⚠️ APNs - client non inizializzato, notifica non inviata")
        return False

    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, lambda: _send_apns_sync(client, device, notification))


def init_fcm(force: bool = False) -> bool:
    """Inizializza Firebase Admin SDK per FCM.
    
    Richiede la variabile d'ambiente FCM_CREDENTIALS_PATH che punta a un file JSON
    del service account Firebase.
    """
    global FCM_ENABLED, FCM_LAST_ERROR
    
    if not FCM_LIB_AVAILABLE:
        print("⚠️ FCM non disponibile: installare la dipendenza 'firebase-admin' (pip install firebase-admin)")
        FCM_ENABLED = False
        FCM_LAST_ERROR = "firebase-admin library missing"
        return False
    
    # Controlla se Firebase è già inizializzato
    try:
        if firebase_admin._apps and not force:
            FCM_ENABLED = True
            FCM_LAST_ERROR = None
            return True
    except Exception:
        pass
    
    credentials_path = os.getenv("FCM_CREDENTIALS_PATH", "").strip()
    
    if not credentials_path:
        print("⚠️ FCM disabilitato: impostare FCM_CREDENTIALS_PATH nell'ambiente")
        FCM_ENABLED = False
        FCM_LAST_ERROR = "missing FCM_CREDENTIALS_PATH"
        return False
    
    if not os.path.exists(credentials_path):
        print(f"❌ FCM credentials file non trovato: {credentials_path}")
        FCM_ENABLED = False
        FCM_LAST_ERROR = f"credentials file not found: {credentials_path}"
        return False
    
    try:
        # Inizializza Firebase Admin con le credenziali del service account
        cred = credentials.Certificate(credentials_path)
        firebase_admin.initialize_app(cred)
        FCM_ENABLED = True
        FCM_LAST_ERROR = None
        print(f"🔥 FCM inizializzato: credentials_path={credentials_path}")
        return True
    except Exception as exc:
        FCM_ENABLED = False
        FCM_LAST_ERROR = str(exc)
        print(f"❌ Errore inizializzazione FCM: {exc}")
        return False


def _send_fcm_sync(
    device: Device,
    notification: Notification,
    *,
    attempt: int = 1,
) -> bool:
    """Invia in modo sincrono una notifica FCM. Da chiamare in executor."""
    if not device.fcm_token:
        return False
    
    # Prepara i dati personalizzati
    data_payload = dict(notification.data or {})
    data_payload.update({
        "notification_id": str(notification.id),
        "sender_id": str(notification.sender_id),
        "notification_type": notification.notification_type.value,
        "timestamp": str(notification.timestamp),
    })
    
    # Prepara il messaggio FCM
    message = messaging.Message(
        token=device.fcm_token,
        notification=messaging.Notification(
            title=notification.title,
            body=notification.body,
        ),
        data={str(k): str(v) for k, v in data_payload.items()},  # FCM richiede stringhe
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(
                sound="default",
                channel_id="default",
            ),
        ),
    )
    
    try:
        with FCM_SEND_LOCK:
            response = messaging.send(message)
        print(
            f"🔥 FCM push inviato a {device.user_id} (token={device.fcm_token[:20]}..., message_id={response})"
        )
        return True
    except messaging.UnregisteredError as exc:
        print(f"❌ FCM ha restituito Unregistered per {device.user_id}: {exc!r}")
        print("   • Rimuovo il token FCM dal dispositivo e disattivo device; servirà una nuova registrazione dal client.")
        device.fcm_token = None
        device.is_active = False
        save_device_to_db(device)
        return False
    except messaging.InvalidArgumentError as exc:
        print(f"❌ FCM token non valido per {device.user_id}: {exc!r}")
        device.fcm_token = None
        device.is_active = False
        save_device_to_db(device)
        return False
    except Exception as exc:
        print(f"❌ Errore invio FCM a {device.user_id}: {exc!r}")
        print(f"   • Tipo eccezione: {type(exc).__name__}")
        stack = traceback.format_exc()
        print(f"   • Stack trace:\n{stack}")
        return False


async def push_via_fcm(device: Device, notification: Notification) -> bool:
    """Invia la notifica tramite FCM sfruttando un executor."""
    if not device.fcm_token:
        print(f"⚠️ FCM - dispositivo {device.user_id} senza token FCM, notifica saltata")
        return False
    
    if not FCM_ENABLED:
        # Prova a inizializzare FCM se non è già stato fatto
        init_fcm()
        if not FCM_ENABLED:
            print("⚠️ FCM - client non inizializzato, notifica non inviata")
            return False
    
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, lambda: _send_fcm_sync(device, notification))

def get_db_connection():
    """Ottiene una connessione PostgreSQL"""
    if not DATABASE_URL:
        raise ValueError("DATABASE_URL non impostato")
    return psycopg.connect(DATABASE_URL)

def init_database():
    """Inizializza il database PostgreSQL per salvare i dispositivi"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Crea la tabella dei dispositivi se non esiste
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS notify_devices (
                device_token VARCHAR(255) PRIMARY KEY,
                user_id VARCHAR(255) NOT NULL,
                platform VARCHAR(50) NOT NULL,
                app_version VARCHAR(50) NOT NULL,
                last_seen DOUBLE PRECISION NOT NULL,
                is_online BOOLEAN NOT NULL DEFAULT TRUE,
                apns_token VARCHAR(255),
                apns_topic VARCHAR(255),
                apns_environment VARCHAR(50),
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        # Aggiungi colonne se non esistono (migrazione)
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS apns_token VARCHAR(255)')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS apns_topic VARCHAR(255)')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS apns_environment VARCHAR(50)')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS fcm_token VARCHAR(255)')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS device_id VARCHAR(255)')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP')
        except Exception:
            pass
        try:
            cursor.execute('ALTER TABLE notify_devices ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP')
        except Exception:
            pass

        # Deduplica token APNs (PostgreSQL)
        cursor.execute('''
            DELETE FROM notify_devices d1
            WHERE apns_token IS NOT NULL
              AND apns_token <> ''
              AND EXISTS (
                  SELECT 1 FROM notify_devices d2
                  WHERE d2.apns_token = d1.apns_token
                    AND d2.device_token < d1.device_token
              )
        ''')
        
        # Deduplica token FCM (PostgreSQL)
        cursor.execute('''
            DELETE FROM notify_devices d1
            WHERE fcm_token IS NOT NULL
              AND fcm_token <> ''
              AND EXISTS (
                  SELECT 1 FROM notify_devices d2
                  WHERE d2.fcm_token = d1.fcm_token
                    AND d2.device_token < d1.device_token
              )
        ''')
        
        # Crea indici se non esistono
        cursor.execute('''
            CREATE INDEX IF NOT EXISTS idx_notify_devices_user_id 
            ON notify_devices(user_id)
        ''')
        cursor.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notify_devices_unique_apns_token
            ON notify_devices(apns_token)
            WHERE apns_token IS NOT NULL AND apns_token <> ''
        ''')
        cursor.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notify_devices_unique_fcm_token
            ON notify_devices(fcm_token)
            WHERE fcm_token IS NOT NULL AND fcm_token <> ''
        ''')
        
        # T0.2: Indici per performance (user_id + platform)
        cursor.execute('''
            CREATE INDEX IF NOT EXISTS idx_notify_devices_user_platform 
            ON notify_devices(user_id, platform)
        ''')
        
        # T0.2: Indice opzionale per (user_id, device_id) univoco se device_id presente
        cursor.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notify_devices_user_device_id
            ON notify_devices(user_id, device_id)
            WHERE device_id IS NOT NULL AND device_id <> ''
        ''')
        
        conn.commit()
        cursor.close()
        conn.close()
        print("💾 Database PostgreSQL dispositivi inizializzato")
    except Exception as e:
        print(f"❌ Errore inizializzazione database PostgreSQL: {e}")
        raise

def save_device_to_db(device: Device):
    """Salva un dispositivo nel database PostgreSQL"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            INSERT INTO notify_devices (
                device_token,
                user_id,
                platform,
                app_version,
                last_seen,
                is_online,
                is_active,
                apns_token,
                apns_topic,
                apns_environment,
                fcm_token,
                device_id,
                updated_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)
            ON CONFLICT (device_token) DO UPDATE SET
                user_id = EXCLUDED.user_id,  -- 🔧 CORREZIONE: Aggiorna sempre user_id quando il dispositivo viene ri-registrato
                platform = EXCLUDED.platform,
                app_version = EXCLUDED.app_version,
                last_seen = EXCLUDED.last_seen,
                is_online = EXCLUDED.is_online,
                is_active = EXCLUDED.is_active,  -- T0.2: Aggiorna is_active
                apns_token = EXCLUDED.apns_token,
                apns_topic = EXCLUDED.apns_topic,
                apns_environment = EXCLUDED.apns_environment,
                fcm_token = EXCLUDED.fcm_token,
                device_id = EXCLUDED.device_id,
                updated_at = CURRENT_TIMESTAMP
        ''', (device.device_token, device.user_id, device.platform, device.app_version, 
              device.last_seen, device.is_online, device.is_active,
              device.apns_token, device.apns_topic, device.apns_environment,
              device.fcm_token, device.device_id))
        
        conn.commit()
        cursor.close()
        conn.close()
        print(f"💾 Dispositivo salvato nel DB PostgreSQL: {device.user_id} ({device.device_token[:20]}...)")
    except Exception as e:
        print(f"❌ Errore salvataggio dispositivo PostgreSQL: {e}")

def delete_device_from_db(device_token: str):
    """Rimuove un dispositivo dal database PostgreSQL."""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('DELETE FROM notify_devices WHERE device_token = %s', (device_token,))
        conn.commit()
        cursor.close()
        conn.close()
        log_debug(f"🗑️ Device {device_token[:20]}... rimosso dal database PostgreSQL")
    except Exception as e:
        print(f"❌ Errore eliminazione dispositivo dal DB PostgreSQL ({device_token[:20]}...): {e}")

def remove_device(device_token: str, *, reason: str = "") -> bool:
    """Rimuove un device dalle strutture in memoria e dal database."""
    device = devices.pop(device_token, None)
    if not device:
        log_debug(f"remove_device: token {device_token[:20]}... non trovato", force=True)
        return False

    user_devices = user_to_devices.get(device.user_id)
    if user_devices:
        user_devices.discard(device_token)
        if not user_devices:
            user_to_devices.pop(device.user_id, None)
    device_to_user.pop(device_token, None)

    delete_device_from_db(device_token)

    reason_text = f" ({reason})" if reason else ""
    print(f"🗑️ Device {device_token[:20]}... rimosso per utente {device.user_id}{reason_text}")
    return True

def prune_devices(*, max_age_seconds: Optional[float] = None, remove_without_apns: bool = True, dry_run: bool = False):
    """Pulisce dispositivi obsoleti o senza APNs token."""
    now = time.time()
    to_remove: List[str] = []

    for token, device in list(devices.items()):
        reason_parts = []
        if remove_without_apns and not device.apns_token:
            reason_parts.append("no_apns_token")
        if max_age_seconds is not None and (now - device.last_seen) > max_age_seconds:
            reason_parts.append(f"stale_{int((now - device.last_seen)//86400)}d")

        if reason_parts:
            reason_str = ",".join(reason_parts)
            if dry_run:
                log_debug(f"[DRY-RUN] Avrei rimosso {token[:20]}... per {reason_str}")
            else:
                if remove_device(token, reason=reason_str):
                    to_remove.append(token)

    return {
        "removed": len(to_remove),
        "tokens": to_remove,
        "dry_run": dry_run,
    }

def limit_user_devices(user_id: str, *, keep_token: Optional[str] = None, max_devices: int = 5):
    """Mantiene sotto controllo il numero di device per utente e rimuove duplicati."""
    tokens = list(user_to_devices.get(user_id, set()))
    if keep_token and keep_token in tokens:
        tokens.remove(keep_token)

    # Calcola priorità: preferisci WebSocket attivo, poi APNs valido, poi last_seen recente
    def _priority(token: str):
        device = devices.get(token)
        if not device:
            return (1, 1, float("inf"))
        has_ws = 0 if device.websocket else 1
        has_apns = 0 if device.apns_token else 1
        last_seen = -(device.last_seen or 0)
        return (has_ws, has_apns, last_seen)

    tokens.sort(key=_priority)

    max_keep = max(0, max_devices - (1 if keep_token else 0))
    kept = 0
    seen_apns: Set[str] = set()
    removed = []

    for token in list(tokens):
        device = devices.get(token)
        if not device:
            remove_device(token, reason="missing_from_memory")
            removed.append(token)
            continue

        apns_token = sanitize_apns_token(device.apns_token) if device.apns_token else None
        if apns_token:
            if apns_token in seen_apns:
                remove_device(token, reason="duplicate_apns_token")
                removed.append(token)
                continue
            seen_apns.add(apns_token)

        if kept < max_keep:
            kept += 1
            continue

        remove_device(token, reason="over_device_limit")
        removed.append(token)

    if keep_token:
        user_to_devices.setdefault(user_id, set()).add(keep_token)

    if removed:
        log_debug(
            f"limit_user_devices: rimossi {len(removed)} device per user {user_id}. "
            f"Rimasti={len(user_to_devices.get(user_id, []))} (keep_token={keep_token[:12] + '...' if keep_token else 'n/a'})"
        )

def load_devices_from_db():
    """Carica tutti i dispositivi dal database PostgreSQL"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT 
                device_token,
                user_id,
                platform,
                app_version,
                last_seen,
                is_online,
                COALESCE(is_active, TRUE) as is_active,  -- T0.2: Default TRUE se NULL (retrocompatibilità)
                apns_token,
                apns_topic,
                apns_environment,
                fcm_token,
                device_id
            FROM notify_devices
        ''')
        rows = cursor.fetchall()
        
        cursor.close()
        conn.close()
        
        loaded_count = 0
        for row in rows:
            (
                device_token,
                user_id,
                platform,
                app_version,
                last_seen,
                is_online,
                is_active,
                apns_token,
                apns_topic,
                apns_environment,
                fcm_token,
                device_id,
            ) = row

            apns_token = sanitize_apns_token(apns_token) if apns_token else None
            
            user_id_str = str(user_id)

            device = Device(
                device_token=device_token,
                user_id=user_id_str,
                platform=platform,
                app_version=app_version,
                last_seen=float(last_seen) if last_seen else time.time(),
                is_online=bool(is_online),
                is_active=bool(is_active) if is_active is not None else True,  # T0.2: Default TRUE se NULL
                apns_token=apns_token,
                apns_topic=apns_topic,
                apns_environment=apns_environment,
                fcm_token=fcm_token,
                device_id=device_id,
                websocket=None
            )
            
            devices[device_token] = device
            user_to_devices.setdefault(user_id_str, set()).add(device_token)
            device_to_user[device_token] = user_id_str
            loaded_count += 1
        
        print(f"💾 Caricati {loaded_count} dispositivi dal database PostgreSQL")
        return loaded_count
    except Exception as e:
        print(f"❌ Errore caricamento dispositivi PostgreSQL: {e}")
        import traceback
        traceback.print_exc()
        return 0

def remove_device_from_db(device_token: str):
    """Rimuove un dispositivo dal database PostgreSQL"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('DELETE FROM notify_devices WHERE device_token = %s', (device_token,))
        
        conn.commit()
        cursor.close()
        conn.close()
        print(f"💾 Dispositivo rimosso dal DB PostgreSQL: {device_token[:20]}...")
    except Exception as e:
        print(f"❌ Errore rimozione dispositivo PostgreSQL: {e}")

def initialize_mappings():
    """Inizializza le mappature all'avvio del server"""
    global user_to_devices, device_to_user
    
    print("🔄 Inizializzazione mappature...")
    print(f"📋 Dispositivi registrati: {len(devices)}")
    
    # Ricarica le mappature dai dispositivi esistenti
    for device_token, device in devices.items():
        user_id = str(device.user_id)
        user_to_devices.setdefault(user_id, set()).add(device_token)
        device_to_user[device_token] = user_id
        print(f"✅ Mappatura: {user_id} -> {device_token[:20]}...")
    
    print(f"📋 Mappature inizializzate:")
    total_device_tokens = sum(len(tokens) for tokens in user_to_devices.values())
    print(f"   - user_to_devices: {len(user_to_devices)} utenti, {total_device_tokens} device")
    print(f"   - device_to_user: {len(device_to_user)} entries")


bootstrap_completed = False


def bootstrap():
    """Bootstrap idempotente per inizializzare database, mappature e APNs."""
    global bootstrap_completed
    if bootstrap_completed:
        return
    print("🛠️ SecureVOX Notify bootstrap...")
    print("💾 Inizializzazione database...")
    init_database()
    loaded = load_devices_from_db()
    print(f"✅ Database pronto! {loaded} dispositivi caricati")
    initialize_mappings()
    init_apns_client()
    init_fcm()  # Inizializza FCM
    bootstrap_completed = True


@app.on_event("startup")
async def on_startup():
    """Hook FastAPI: esegue il bootstrap alla partenza del server."""
    bootstrap()

def generate_notification_id() -> str:
    global notification_counter
    notification_counter += 1
    return f"notif_{int(time.time() * 1000)}_{notification_counter}"

def generate_call_id() -> str:
    global call_counter
    call_counter += 1
    return f"call_{int(time.time() * 1000)}_{call_counter}"

async def fetch_backend_unread_count(user_id: Optional[str]) -> Optional[int]:
    """Recupera il conteggio badge reale dal backend Django, se configurato."""
    if not user_id:
        return None
    if not BACKEND_BASE_URL:
        return None
    try:
        import aiohttp
        url = f"{BACKEND_BASE_URL}/api/notifications/unread-count/{user_id}/"
        headers = {}
        if SERVICE_AUTH_KEY:
            headers["X-Notify-Service-Key"] = SERVICE_AUTH_KEY
        timeout = aiohttp.ClientTimeout(total=BACKEND_TIMEOUT)
        log_debug(f"fetch_backend_unread_count -> GET {url} headers={headers}")
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url, headers=headers) as response:
                log_debug(f"fetch_backend_unread_count <- status={response.status}")
                if response.status == 200:
                    data = await response.json()
                    log_debug(f"fetch_backend_unread_count <- data={data}")
                    unread = data.get("unread_count")
                    if isinstance(unread, (int, float)):
                        return max(int(unread), 0)
                elif response.status == 404:
                    log_debug("fetch_backend_unread_count -> 404, ritorno 0")
                    return 0
                else:
                    body_text = await response.text()
                    print(
                        "⚠️ Backend unread count fallito: "
                        f"user_id={user_id} status={response.status} body={body_text}"
                    )
    except Exception as exc:
        print(f"❌ Errore recupero badge backend per user {user_id}: {exc}")
    return None

async def auto_timeout_call(call_id: str, timeout_seconds: int):
    """Timeout automatico per chiamate non risposte"""
    await asyncio.sleep(timeout_seconds)
    
    if call_id in active_calls:
        call_info = active_calls[call_id]
        if call_info["status"] == CallStatus.INCOMING:
            # Chiamata non risposta - imposta come MISSED
            call_info["status"] = CallStatus.MISSED
            call_info["end_time"] = time.time()
            call_info["duration"] = int(call_info["end_time"] - call_info["start_time"])
            
            # Notifica il chiamante
            caller_notification = {
                "type": "call_status",
                "call_id": call_id,
                "status": CallStatus.MISSED.value,
                "message": "Chiamata non risposta",
                "timestamp": time.time()
            }
            await send_websocket_notification(call_info["sender_id"], caller_notification)
            
            # Notifica il destinatario (chiamata persa)
            missed_notification = {
                "type": "call_missed",
                "call_id": call_id,
                "caller_id": call_info["sender_id"],
                "call_type": call_info["call_type"],
                "timestamp": time.time()
            }
            await send_websocket_notification(call_info["recipient_id"], missed_notification)
            
            print(f"📞 Chiamata {call_id} scaduta per timeout (non risposta)")

async def integrate_with_webrtc_server(call_id: str, action: str, user_data: dict = None):
    """Integra con il server WebRTC Django per gestire le sessioni"""
    try:
        import aiohttp
        webrtc_url = "http://localhost:8000/api/webrtc"
        
        async with aiohttp.ClientSession() as session:
            if action == "create_session":
                # Crea sessione WebRTC per chiamata 1:1
                async with session.post(
                    f"{webrtc_url}/calls/create/",
                    json={
                        "callee_id": user_data.get("recipient_id"),
                        "call_type": user_data.get("call_type", "video")
                    },
                    headers={"Authorization": f"Token {user_data.get('auth_token')}"}
                ) as response:
                    if response.status == 200:
                        session_data = await response.json()
                        return session_data
                        
            elif action == "create_group_session":
                # Crea sessione WebRTC per chiamata di gruppo
                async with session.post(
                    f"{webrtc_url}/calls/group/",
                    json={
                        "room_name": user_data.get("room_name", "Group Call"),
                        "max_participants": user_data.get("max_participants", 10),
                        "call_type": user_data.get("call_type", "video")
                    },
                    headers={"Authorization": f"Token {user_data.get('auth_token')}"}
                ) as response:
                    if response.status == 200:
                        session_data = await response.json()
                        return session_data
                    
            elif action == "end_session":
                # Termina sessione WebRTC
                async with session.post(
                    f"{webrtc_url}/calls/end/",
                    json={"session_id": call_id},
                    headers={"Authorization": f"Token {user_data.get('auth_token')}"}
                ) as response:
                    return response.status == 200
                    
    except Exception as e:
        print(f"❌ Errore integrazione WebRTC per {action}: {e}")
        return None

async def send_websocket_notification(user_id: str, notification_data: Dict, correlation_id: str = None) -> bool:
    """Invia notifica tramite WebSocket a tutti i dispositivi online dell'utente."""
    # OBSERVABILITY B1: Includi correlation_id nel payload se disponibile
    if correlation_id:
        notification_data['correlation_id'] = correlation_id
    
    delivered = False
    user_id_str = str(user_id)
    tokens = list(user_to_devices.get(user_id_str, set()))
    
    print(f"📡 send_websocket_notification - user_id={user_id_str}, tokens trovati={len(tokens)}, tipo={notification_data.get('type')}")
    
    if not tokens:
        print(f"⚠️ send_websocket_notification: nessun token per user {user_id_str}")
        print(f"🔍 DEBUG: user_to_devices contiene {len(user_to_devices)} utenti")
        print(f"🔍 DEBUG: Chiavi user_to_devices: {list(user_to_devices.keys())[:10]}")
        log_debug(f"send_websocket_notification: nessun token per user {user_id_str}")
        return False

    # 🚀 FIX: Verifica e pulisci dispositivi con WebSocket disconnessi
    active_devices = []
    for device_token in tokens:
        device = devices.get(device_token)
        if not device:
            print(f"⚠️ send_websocket_notification: device {device_token[:12]}... non trovato in memoria, rimuovo dalla mappa")
            user_to_devices.get(user_id_str, set()).discard(device_token)
            device_to_user.pop(device_token, None)
            continue
        
        # 🚀 FIX: Verifica se il WebSocket è ancora valido
        if device.websocket:
            try:
                # Prova a verificare se il WebSocket è ancora connesso
                # Se il WebSocket è chiuso, verrà rilevato quando si tenta di inviare
                active_devices.append((device_token, device))
            except Exception:
                print(f"⚠️ send_websocket_notification: WebSocket non valido per device {device_token[:12]}..., rimuovo")
                device.websocket = None
                device.is_online = False
        else:
            print(f"⚠️ send_websocket_notification: device {device_token[:12]}... offline (no websocket) per user {user_id_str}")
            log_debug(f"send_websocket_notification: device {device_token[:12]}... offline per user {user_id_str}")

    # 🚀 FIX: Se non ci sono dispositivi attivi, logga dettagliatamente
    if not active_devices:
        print("")
        print("=" * 80)
        print("❌ SERVER NOTIFY - NESSUN WEBSOCKET ATTIVO")
        print("=" * 80)
        print(f"❌ User ID: {user_id_str}")
        print(f"❌ Totale dispositivi registrati: {len(tokens)}")
        print(f"❌ Dispositivi con WebSocket attivo: 0")
        for device_token in tokens:
            device = devices.get(device_token)
            if device:
                print(f"   - Device {device_token[:20]}...: websocket={'✅' if device.websocket else '❌'}, is_online={device.is_online}, last_seen={device.last_seen}")
        print("=" * 80)
        print("")
        return False

    # Invia a tutti i dispositivi attivi
    for device_token, device in active_devices:
        try:
            # OBSERVABILITY B1: Includi ws_conn_id nel payload se disponibile
            payload_data = notification_data.copy()
            if device.ws_conn_id:
                payload_data['ws_conn_id'] = device.ws_conn_id
            
            payload = json.dumps(payload_data)
            await device.websocket.send_text(payload)
            delivered = True
            
            # OBSERVABILITY B1: Log strutturato JSON
            print(json.dumps({
                'timestamp': datetime.utcnow().isoformat() + 'Z',
                'level': 'INFO',
                'service': 'notify',
                'event_type': 'ws.send.success',
                'correlation_id': correlation_id,
                'ws_conn_id': device.ws_conn_id,
                'device_id_hash': device.device_id_hash or hashlib.sha256(device_token.encode()).hexdigest()[:16],
                'user_id': user_id_str,
                'status': 'success',
            }))
            
            # OBSERVABILITY B2: Metrics stub
            if 'notify_metrics' in globals():
                notify_metrics.increment_counter(
                    'ws_send_total',
                    labels={
                        'status': 'success',
                        'notification_type': notification_data.get('type', 'unknown')
                    }
                )
        except Exception as e:
            # OBSERVABILITY B1: Log errore strutturato JSON
            print(json.dumps({
                'timestamp': datetime.utcnow().isoformat() + 'Z',
                'level': 'ERROR',
                'service': 'notify',
                'event_type': 'ws.send.fail',
                'correlation_id': correlation_id,
                'ws_conn_id': device.ws_conn_id,
                'device_id_hash': device.device_id_hash or hashlib.sha256(device_token.encode()).hexdigest()[:16],
                'user_id': user_id_str,
                'status': 'fail',
                'error_code': type(e).__name__,
            }))
            
            # OBSERVABILITY B2: Metrics stub
            if 'notify_metrics' in globals():
                notify_metrics.increment_counter(
                    'ws_send_total',
                    labels={
                        'status': 'fail',
                        'notification_type': notification_data.get('type', 'unknown')
                    }
                )
                notify_metrics.increment_counter(
                    'ws_send_fail_total',
                    labels={'error_type': 'disconnected'}
                )
            
            # 🚀 FIX: Pulisci il WebSocket disconnesso
            device.websocket = None
            device.is_online = False
            log_debug(f"WS errore per {user_id_str} device {device_token[:12]}...: {e}")
    
    print(f"📡 send_websocket_notification - Risultato finale: delivered={delivered} per user {user_id_str}")
    return delivered

def cleanup_old_notifications():
    """Rimuove notifiche più vecchie di 1 ora"""
    current_time = time.time()
    for user_id in list(notifications.keys()):
        notifications[user_id] = [
            notif for notif in notifications[user_id]
            if current_time - notif.timestamp < 3600  # 1 ora
        ]
        if not notifications[user_id]:
            del notifications[user_id]

def verify_service_key(request: Request) -> None:
    """Verifica SERVICE_AUTH_KEY dall'header X-Notify-Service-Key.
    Solleva HTTPException 401 se la chiave non è valida."""
    if not SERVICE_AUTH_KEY:
        return
    
    provided_key = (
        request.headers.get("X-Notify-Service-Key")
        or request.headers.get("X-Service-Key")
    )
    normalized = (provided_key or "").strip()
    
    if normalized != SERVICE_AUTH_KEY:
        print(f"🚫 Tentativo non autorizzato: chiave fornita={normalized[:10] if len(normalized) > 10 else normalized}... (attesa={SERVICE_AUTH_KEY[:10]}...)")
        raise HTTPException(status_code=401, detail="Unauthorized: invalid service key")

def build_unified_payload(
    notification_type: str,
    title: str,
    body: str,
    data: Dict,
    timestamp: Optional[float] = None
) -> Dict:
    """Costruisce un payload unificato per notifiche.
    
    Returns:
        Dict con title, body, data (tutti i campi unificati)
    """
    if timestamp is None:
        timestamp = time.time()
    
    unified_data = dict(data or {})
    unified_data.update({
        "type": notification_type,
        "timestamp": str(timestamp) if isinstance(timestamp, (int, float)) else timestamp,
    })
    
    return {
        "title": title,
        "body": body,
        "data": unified_data,
        "timestamp": timestamp,
    }

@app.post("/register")
async def register_device(device_data: DeviceRegistration, request: Request):
    """Registra un nuovo dispositivo per le notifiche"""
    verify_service_key(request)
    
    try:
        # Validazioni platform-specific
        platform_lower = (device_data.platform or "").lower().strip()
        if platform_lower not in {"ios", "android"}:
            raise HTTPException(
                status_code=400,
                detail=f"platform must be 'ios' or 'android', got: {device_data.platform}"
            )
        
        if platform_lower == "ios":
            if not device_data.apns_token or not device_data.apns_token.strip():
                raise HTTPException(
                    status_code=400,
                    detail="apns_token is required and cannot be empty for iOS devices"
                )
        
        if platform_lower == "android":
            if not device_data.fcm_token or not device_data.fcm_token.strip():
                raise HTTPException(
                    status_code=400,
                    detail="fcm_token is required and cannot be empty for Android devices"
                )
        
        print("")
        print("=" * 80)
        print("🔥 SERVER NOTIFY - RICEVUTA RICHIESTA REGISTRAZIONE DISPOSITIVO")
        print("=" * 80)
        print(f"🔥 Device Token: {device_data.device_token}")
        print(f"🔥 User ID: {device_data.user_id}")
        print(f"🔥 Platform: {device_data.platform}")
        print(f"🔥 App Version: {device_data.app_version}")
        print(f"🔥 APNs Token: {device_data.apns_token[:50] if device_data.apns_token else 'N/A'}...")
        print(f"🔥 FCM Token: {device_data.fcm_token[:50] if device_data.fcm_token else 'N/A'}...")
        print(f"🔥 Device ID: {device_data.device_id or 'N/A'}")
        print("=" * 80)
        print("")
        
        apns_token = sanitize_apns_token(device_data.apns_token) if device_data.apns_token else None
        apns_topic = device_data.apns_topic or APNS_TOPIC
        apns_environment = normalize_apns_environment(
            device_data.apns_environment or ("sandbox" if APNS_USE_SANDBOX else "production")
        )

        if APNS_USE_SANDBOX and apns_environment == "production":
            print("⚠️ APNs - Server in modalità sandbox, forzo l'ambiente a 'sandbox' nonostante la richiesta 'production'")
            apns_environment = "sandbox"

        user_id_str = str(device_data.user_id)
        
        # Deduplicazione token: se apns_token/fcm_token esiste già, aggiorna record esistente
        conn_db = get_db_connection()
        cursor_db = conn_db.cursor()
        actual_device_token = device_data.device_token
        
        if apns_token:
            cursor_db.execute(
                'SELECT device_token FROM notify_devices WHERE apns_token=%s AND apns_token IS NOT NULL AND apns_token <> %s',
                (apns_token, '')
            )
            existing_device = cursor_db.fetchone()
            if existing_device:
                actual_device_token = existing_device[0]
                print(f"🔄 Dedup APNs token: token già esistente, aggiorno device_token={actual_device_token}")
        
        if device_data.fcm_token:
            cursor_db.execute(
                'SELECT device_token FROM notify_devices WHERE fcm_token=%s AND fcm_token IS NOT NULL AND fcm_token <> %s',
                (device_data.fcm_token, '')
            )
            existing_device = cursor_db.fetchone()
            if existing_device:
                actual_device_token = existing_device[0]
                print(f"🔄 Dedup FCM token: token già esistente, aggiorno device_token={actual_device_token}")
        
        # Deduplicazione device_id: disattiva device precedenti con stesso (user_id, device_id)
        if device_data.device_id and device_data.device_id.strip():
            cursor_db.execute(
                'UPDATE notify_devices SET is_active=false WHERE user_id=%s AND device_id=%s AND device_token!=%s',
                (user_id_str, device_data.device_id, actual_device_token)
            )
            deactivated_count = cursor_db.rowcount
            if deactivated_count > 0:
                print(f"🔄 Dedup device_id: disattivati {deactivated_count} device precedenti con (user_id={user_id_str}, device_id={device_data.device_id})")
        
        conn_db.commit()
        cursor_db.close()
        conn_db.close()

        device = Device(
            device_token=actual_device_token,
            user_id=user_id_str,
            platform=device_data.platform,
            app_version=device_data.app_version,
            last_seen=time.time(),
            is_online=True,
            is_active=True,
            apns_token=apns_token,
            apns_topic=apns_topic,
            apns_environment=apns_environment,
            fcm_token=device_data.fcm_token,
            device_id=device_data.device_id
        )
        
        devices[actual_device_token] = device
        
        # Aggiorna le mappature user_id <-> device_token
        previous_user = device_to_user.get(actual_device_token)
        if previous_user and previous_user != user_id_str:
            tokens = user_to_devices.get(previous_user)
            if tokens and actual_device_token in tokens:
                tokens.discard(actual_device_token)
                if not tokens:
                    user_to_devices.pop(previous_user, None)
        user_to_devices.setdefault(user_id_str, set()).add(actual_device_token)
        device_to_user[actual_device_token] = user_id_str

        # Limita dispositivi in memoria e rimuovi duplicati (prima di salvare su DB)
        limit_user_devices(user_id_str, keep_token=actual_device_token, max_devices=5)

        # 💾 SALVA NEL DATABASE PERSISTENTE
        save_device_to_db(device)
        
        print(f"🔥 Dispositivo registrato: {device_data.user_id} ({device_data.platform})")
        print(f"🔥 Token: {actual_device_token[:20]}...")
        print(f"📋 Mappature aggiornate:")
        total_device_tokens = sum(len(tokens) for tokens in user_to_devices.values())
        print(f"   - user_to_devices: {len(user_to_devices)} utenti, {total_device_tokens} device")
        print(f"   - device_to_user: {len(device_to_user)} entries")
        if apns_token:
            print(f"📬 APNs registrato per {device_data.user_id} (env={apns_environment}, topic={apns_topic})")
        else:
            if device_data.platform.lower() == "ios":
                print("⚠️ Nessun token APNs ricevuto per un dispositivo iOS - le push non verranno recapitate in background")
        
        if device_data.fcm_token:
            print(f"🔥 FCM registrato per {device_data.user_id} (token={device_data.fcm_token[:20]}...)")
        else:
            if device_data.platform.lower() == "android":
                print("⚠️ Nessun token FCM ricevuto per un dispositivo Android - le push non verranno recapitate in background")
        
        return {
            "status": "success",
            "device_id": actual_device_token,
            "platform": device_data.platform,
            "is_active": True
        }
        
    except Exception as e:
        print(f"❌ Errore nella registrazione dispositivo: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/unregister")
async def unregister_device(unregister_data: DeviceUnregister, request: Request):
    """Disattiva un dispositivo per le notifiche"""
    verify_service_key(request)
    
    try:
        user_id = str(unregister_data.user_id)
        device_token = unregister_data.device_token
        apns_token = sanitize_apns_token(unregister_data.apns_token) if unregister_data.apns_token else None
        fcm_token = unregister_data.fcm_token
        
        # T2: Validazione: almeno un identificatore deve essere presente
        if not device_token and not apns_token and not fcm_token:
            raise HTTPException(
                status_code=400,
                detail="At least one identifier must be provided: device_token, apns_token, or fcm_token"
            )
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # T2: Costruisci condizioni per WHERE
        conditions = ["user_id=%s"]
        params = [user_id]
        
        if device_token:
            conditions.append("device_token=%s")
            params.append(device_token)
        if apns_token:
            conditions.append("apns_token=%s")
            params.append(apns_token)
        if fcm_token:
            conditions.append("fcm_token=%s")
            params.append(fcm_token)
        
        # T2: UPDATE con is_active=false, token=NULL, updated_at se esiste
        query = f"""UPDATE notify_devices 
                    SET is_active=false, 
                        apns_token=NULL, 
                        fcm_token=NULL,
                        updated_at=CURRENT_TIMESTAMP 
                    WHERE {' AND '.join(conditions)}"""
        cursor.execute(query, params)
        affected = cursor.rowcount
        
        conn.commit()
        cursor.close()
        conn.close()
        
        # T2: Rimuovi da cache in-memory se presente
        if device_token and device_token in devices:
            remove_device(device_token, reason="unregistered")
        
        # T2: Rimuovi anche per token APNs/FCM se presente
        devices_to_remove = []
        for token, device in devices.items():
            if device.user_id == user_id:
                if apns_token and device.apns_token == apns_token:
                    devices_to_remove.append(token)
                if fcm_token and device.fcm_token == fcm_token:
                    devices_to_remove.append(token)
        
        for token in devices_to_remove:
            if token in devices:
                remove_device(token, reason="unregistered_by_token")
        
        print(f"🗑️ Device unregistered: user_id={user_id}, affected={affected}")
        
        # T2: Idempotenza: ritorna success anche se affected=0
        return {"status": "success", "message": "unregistered", "affected": affected}
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Errore nella disattivazione dispositivo: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/cleanup")
async def cleanup_inactive_devices(request: Request):
    """T2: Cleanup dispositivi inattivi (last_seen più vecchio di N giorni)"""
    verify_service_key(request)
    
    try:
        import os
        retention_days = int(os.getenv('DEVICE_RETENTION_DAYS', '45'))
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # T2: Disattiva device con last_seen più vecchio di retention_days giorni
        query = """
            UPDATE notify_devices 
            SET is_active=false, 
                apns_token=NULL, 
                fcm_token=NULL,
                updated_at=CURRENT_TIMESTAMP 
            WHERE is_active=true 
              AND last_seen < CURRENT_TIMESTAMP - INTERVAL '%s days'
        """
        cursor.execute(query, [retention_days])
        affected = cursor.rowcount
        
        conn.commit()
        cursor.close()
        conn.close()
        
        print(f"🧹 T2: Cleanup dispositivi inattivi completato: {affected} device disattivati (retention: {retention_days} giorni)")
        
        return {
            "status": "success",
            "message": f"Cleanup completed: {affected} devices deactivated",
            "affected": affected,
            "retention_days": retention_days
        }
        
    except Exception as e:
        print(f"❌ Errore cleanup dispositivi: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/send")
async def send_notification(notification_data: NotificationRequest, request: Request):
    """OBSERVABILITY B1: Invia una notifica a un destinatario"""
    verify_service_key(request)
    
    # OBSERVABILITY B1: Estrai correlation IDs dagli header
    request_id = request.headers.get('x-request-id')
    correlation_id = request.headers.get('x-correlation-id')
    
    # GO-LIVE P1: Input validation hardening
    try:
        # Validazione size payload (max 16KB)
        import json
        payload_size = len(json.dumps(notification_data.dict()).encode('utf-8'))
        MAX_PAYLOAD_SIZE = 16 * 1024  # 16KB
        if payload_size > MAX_PAYLOAD_SIZE:
            print(f"⚠️ GO-LIVE: Payload troppo grande: {payload_size} bytes (max {MAX_PAYLOAD_SIZE})")
            return {"status": "error", "message": f"Payload troppo grande: {payload_size} bytes (max {MAX_PAYLOAD_SIZE})"}
        
        # Validazione campi richiesti per event type
        if notification_data.notification_type in [NotificationType.CALL, NotificationType.VIDEO_CALL]:
            data = notification_data.data if isinstance(notification_data.data, dict) else {}
            if 'call_id' not in data:
                print(f"⚠️ GO-LIVE: call_id mancante per event type {notification_data.notification_type}")
                return {"status": "error", "message": "call_id richiesto per event type call"}
        
        if notification_data.notification_type in [NotificationType.GROUP_CALL, NotificationType.GROUP_VIDEO_CALL]:
            data = notification_data.data if isinstance(notification_data.data, dict) else {}
            if 'room_id' not in data:
                print(f"⚠️ GO-LIVE: room_id mancante per event type {notification_data.notification_type}")
                return {"status": "error", "message": "room_id richiesto per event type group_call"}
        
        # Validazione recipient_id e sender_id
        if not notification_data.recipient_id or not notification_data.recipient_id.strip():
            print(f"⚠️ GO-LIVE: recipient_id vuoto o mancante")
            return {"status": "error", "message": "recipient_id richiesto"}
        
        if not notification_data.sender_id or not notification_data.sender_id.strip():
            print(f"⚠️ GO-LIVE: sender_id vuoto o mancante")
            return {"status": "error", "message": "sender_id richiesto"}
    except Exception as e:
        print(f"❌ GO-LIVE: Errore validazione input: {e}")
        return {"status": "error", "message": f"Errore validazione input: {str(e)}"}
    
    try:
        print("")
        print("=" * 80)
        print("📨 SERVER NOTIFY - RICEVUTA RICHIESTA NOTIFICA")
        print("=" * 80)
        print(f"📨 Tipo: {notification_data.notification_type}")
        print(f"📨 Recipient ID: {notification_data.recipient_id}")
        print(f"📨 Sender ID: {notification_data.sender_id}")
        print(f"📨 Title: {notification_data.title}")
        print(f"📨 Body: {notification_data.body[:100] if notification_data.body else 'N/A'}")
        print(f"📨 Encrypted: {notification_data.encrypted}")
        if notification_data.notification_type == NotificationType.MESSAGE:
            data = notification_data.data if isinstance(notification_data.data, dict) else {}
            print(f"📨 MESSAGE DATA:")
            print(f"📨   Message ID: {data.get('message_id', 'N/A')}")
            print(f"📨   Chat ID: {data.get('chat_id', 'N/A')}")
            print(f"📨   Content: {str(data.get('content', 'N/A'))[:100]}")
            print(f"📨   Message Type: {data.get('message_type', 'N/A')}")
            print(f"📨   Sender Name: {data.get('sender_name', 'N/A')}")
            print(f"📨   Timestamp: {data.get('timestamp', 'N/A')}")
        else:
            print(f"📨 Data: {notification_data.data}")
        print(f"📨 Timestamp: {notification_data.timestamp}")
        print("=" * 80)
        print("")
        
        # OBSERVABILITY B1: Log strutturato JSON con correlation IDs ricevuti
        print(json.dumps({
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'level': 'INFO',
            'service': 'notify',
            'event_type': 'notification.received',
            'request_id': request_id,
            'correlation_id': correlation_id,
            'notification_type': notification_data.notification_type.value,
            'recipient_id': notification_data.recipient_id,
            'sender_id': notification_data.sender_id,
        }))
        
        log_debug(f"/send payload: {notification_data.dict()}")
        # 🔧 FALLBACK: Se devices è vuoto, ricarica dal database
        if len(devices) == 0:
            print("⚠️ Dizionario devices vuoto, ricaricamento dal database...")
            load_devices_from_db()
            initialize_mappings()
            print(f"✅ Ricaricati {len(devices)} dispositivi dal database")
        
        # Trova i dispositivi del destinatario usando le mappature
        recipient_user_id: Optional[str] = None
        recipient_devices: List[Device] = []
        
        recipient_key = str(notification_data.recipient_id)
        print(f"🔍 Cercando recipient_id: {notification_data.recipient_id} (tipo: {type(notification_data.recipient_id)})")
        print(f"🔍 user_to_devices: {len(user_to_devices)} utenti totali")
        if recipient_key in user_to_devices:
            print(f"🔍 user_to_devices[{recipient_key}] -> {len(user_to_devices.get(recipient_key, []))} device registrati")
        else:
            print("🔍 user_to_devices non contiene ancora il destinatario")
        
        if recipient_key in user_to_devices:
            recipient_user_id = recipient_key
            tokens = list(user_to_devices.get(recipient_key, set()))
            detailed_logged = 0
            missing_logged = 0
            for token in tokens:
                device = devices.get(token)
                if device:
                    recipient_devices.append(device)
                    if detailed_logged < 3:
                        print(f"✅ Device trovato per user_id {recipient_user_id}: {token[:20]}...")
                        detailed_logged += 1
                else:
                    if missing_logged < 3:
                        print(f"⚠️ Token {token[:20]}... non presente in devices, lo rimuovo dalla mappa")
                        missing_logged += 1
                    user_to_devices.get(recipient_key, set()).discard(token)
            extra = len(recipient_devices) - detailed_logged
            if extra > 0:
                print(f"✅ (+{extra}) altri device caricati per user_id {recipient_user_id}")
            if (len(tokens) - len(recipient_devices)) - missing_logged > 0:
                print(f"⚠️ Rimossi {len(tokens) - len(recipient_devices)} token indesiderati per user_id {recipient_user_id}")
        elif notification_data.recipient_id in device_to_user:
            device_token = notification_data.recipient_id
            recipient_user_id = device_to_user[device_token]
            device = devices.get(device_token)
            if device:
                recipient_devices.append(device)
                user_to_devices.setdefault(recipient_user_id, set()).add(device_token)
                print(f"📤 Notifica per device_token: {device_token[:20]}... -> user_id: {recipient_user_id}")
        else:
            print(f"⚠️ Recipient ID non trovato nelle mappature: {notification_data.recipient_id}")
            print(f"📋 User IDs disponibili: {list(user_to_devices.keys())}")
            print(f"📋 Device tokens disponibili: {list(device_to_user.keys())}")
            print(f"📋 Dispositivi registrati: {len(devices)}")
            log_debug(f"Recipient {notification_data.recipient_id} non trovato, eseguo ricerca completa tra {len(devices)} dispositivi.")
            
            # Prova a cercare per user_id nei dispositivi
            for device_token, device in devices.items():
                print(f"🔍 Controllo dispositivo: {device_token[:20]}... -> user_id: {device.user_id}")
                if str(device.user_id) == recipient_key:
                    recipient_user_id = str(device.user_id)
                    recipient_devices.append(device)
                    user_to_devices.setdefault(recipient_user_id, set()).add(device_token)
                    device_to_user[device_token] = recipient_user_id
                    print(f"✅ Dispositivo trovato per user_id: {device.user_id}")
        
        if not recipient_devices:
            print(f"❌ Dispositivi destinatari non trovati: {notification_data.recipient_id}")
            return {"status": "error", "message": "Destinatario non trovato"}
        else:
            log_debug(f"Dispositivi destinatari per {recipient_user_id}: {len(recipient_devices)}")
        
        # Ordina dispositivi per priorità (WS > APNs > recente)
        def _device_priority(dev: Device):
            return (
                0 if dev.websocket else 1,
                0 if dev.apns_token else 1,
                -(dev.last_seen or 0),
            )

        recipient_devices.sort(key=_device_priority)

        # Assicura coerenza mappature
        for device in recipient_devices:
            user_to_devices.setdefault(device.user_id, set()).add(device.device_token)
            device_to_user[device.device_token] = device.user_id
        
        if not recipient_user_id:
            recipient_user_id = recipient_devices[0].user_id
        
        # Filtra solo device attivi
        recipient_devices = [d for d in recipient_devices if d.is_active]
        print(f"🔍 Device attivi per recipient {recipient_user_id}: {len(recipient_devices)} (filtrati da is_active=true)")
        
        # 🔐 E2EE: Gestione notifiche cifrate
        if notification_data.encrypted and notification_data.encrypted_payload:
            print(f"🔐 Notifica CIFRATA ricevuta per {notification_data.recipient_id}")
            # Notifica cifrata: usa placeholder generici
            title = "🔐 Nuovo messaggio"  # Placeholder generico
            body = "Hai ricevuto un nuovo messaggio"  # Placeholder generico
            
            # Includi payload cifrato nei dati
            notification_data_dict = {
                'encrypted': True,
                'encrypted_payload': notification_data.encrypted_payload,
                'sender_id': notification_data.sender_id,
                'notification_type': notification_data.notification_type.value,
                'timestamp': notification_data.timestamp
            }
            print(f"🔐 Payload cifrato: ciphertext={len(notification_data.encrypted_payload.get('ciphertext', ''))} bytes")
        
        # Gestione speciale per eliminazione chat
        elif notification_data.notification_type == NotificationType.CHAT_DELETED:
            # Per eliminazione chat, usa i dati dal payload
            title = f"Chat eliminata"
            body = f"La chat '{notification_data.data.get('chat_name', 'Chat')}' è stata eliminata"
            notification_data_dict = notification_data.data.copy()
            notification_data_dict.update({
                'type': 'chat_deleted',
                'chat_id': notification_data.data.get('chat_id'),
                'chat_name': notification_data.data.get('chat_name'),
                'deleted_by': notification_data.data.get('deleted_by'),
                'deleted_by_name': notification_data.data.get('deleted_by_name'),
                'timestamp': notification_data.data.get('timestamp')
            })
        # C1: Gestione chiamate (wake-up call e call_event)
        elif notification_data.notification_type == NotificationType.CALL:
            data = notification_data.data if isinstance(notification_data.data, dict) else {}
            data_type = data.get('type', '')
            
            if data_type == 'call':
                # Wake-up call: notifica incoming call
                title = "Chiamata in arrivo"
                call_type = data.get('call_type', 'audio')
                body = f"Chiamata {'video' if call_type == 'video' else 'audio'} in arrivo"
                notification_data_dict = data.copy()
                # Garantire che type sia presente
                notification_data_dict['type'] = 'call'
            elif data_type == 'call_event':
                # Evento chiamata: accepted/rejected/ended/missed
                event = data.get('event', 'unknown')
                title = f"Chiamata {event}"
                if event == 'accepted':
                    body = "Chiamata accettata"
                elif event == 'rejected':
                    body = "Chiamata rifiutata"
                elif event == 'ended':
                    body = "Chiamata terminata"
                elif event == 'missed':
                    body = "Chiamata persa"
                else:
                    body = f"Evento chiamata: {event}"
                notification_data_dict = data.copy()
                # Garantire che type sia presente
                notification_data_dict['type'] = 'call_event'
            elif data_type == 'group_call_event':
                # C4-B: Evento group call: incoming/joined/left/ended/missed/signal_available
                event = data.get('event', 'unknown')
                room_id = data.get('room_id', 'unknown')
                title = f"Chiamata gruppo {event}"
                if event == 'incoming':
                    body = f"Invito a chiamata gruppo (stanza {room_id[:8]}...)"
                elif event == 'joined':
                    body = f"Partecipante si è unito alla stanza {room_id[:8]}..."
                elif event == 'left':
                    body = f"Partecipante ha lasciato la stanza {room_id[:8]}..."
                elif event == 'ended':
                    body = f"Chiamata gruppo terminata (stanza {room_id[:8]}...)"
                elif event == 'missed':
                    body = f"Invito gruppo scaduto (stanza {room_id[:8]}...)"
                elif event == 'signal_available':
                    body = f"Nuovo segnale disponibile (stanza {room_id[:8]}...)"
                else:
                    body = f"Evento gruppo: {event}"
                notification_data_dict = data.copy()
                # Garantire che type sia presente
                notification_data_dict['type'] = 'group_call_event'
            else:
                # Fallback per chiamate senza type specificato
                title = "Chiamata"
                body = "Notifica chiamata"
                notification_data_dict = data.copy() if data else {}
                notification_data_dict['type'] = 'call'
        else:
            # Notifica non cifrata (legacy)
            title = notification_data.title
            body = notification_data.body
            notification_data_dict = dict(notification_data.data or {})
            
            # T1.1: Garantire che type sia sempre presente in data
            if 'type' not in notification_data_dict:
                notification_data_dict['type'] = notification_data.notification_type.value

        # Crea la notifica usando il recipient_user_id corretto
        notification = Notification(
            id=generate_notification_id(),
            recipient_id=recipient_user_id or notification_data.recipient_id,
            title=title,
            body=body,
            data=notification_data_dict,
            sender_id=notification_data.sender_id,
            timestamp=time.time(),
            notification_type=notification_data.notification_type,
            delivered=False
        )
        
        # 🔧 CORREZIONE: Assicura che recipient_user_id sia sempre una stringa
        recipient_user_id = str(recipient_user_id) if recipient_user_id else None
        if not recipient_user_id:
            print(f"❌ recipient_user_id è None, impossibile salvare la notifica")
            return {"status": "error", "message": "Recipient user ID is None"}
        
        # Aggiungi la notifica alla coda del destinatario con deduplicazione
        queue = notifications.setdefault(recipient_user_id, [])
        
        # Deduplicazione: message_id per messaggi, (call_id, event) per chiamate
        message_id = extract_message_id(notification.data)
        if message_id:
            for existing in queue:
                if extract_message_id(existing.data) == message_id:
                    log_debug(f"Notifica duplicata per utente {recipient_user_id} (message_id={message_id}), salto invio.")
                    return {
                        "status": "duplicate",
                        "message": "Notification already queued",
                        "notification_id": existing.id,
                    }
        
        # C2-NOTIFY: Deduplicazione per call_event con TTL cache: (call_id, event, by_user_id)
        notification_data = notification.data if isinstance(notification.data, dict) else {}
        event_data = notification_data.get('data', {}) if isinstance(notification_data.get('data'), dict) else {}
        data_type = event_data.get('type', '')
        dedup_hit = False
        delivery_channel = None  # Will be set later
        
        if data_type == 'call_event':
            call_id = event_data.get('call_id')
            event = event_data.get('event')
            by_user_id = event_data.get('by_user_id')
            
            if call_id and event:
                # C2-NOTIFY: Cleanup cache TTL (rimuovi entry più vecchie di TTL)
                now_ts = time.time()
                expired_keys = [
                    key for key, ts in _call_event_dedup_cache.items()
                    if (now_ts - ts) > _CALL_EVENT_DEDUP_TTL_SECONDS
                ]
                for key in expired_keys:
                    _call_event_dedup_cache.pop(key, None)
                
                # C2-NOTIFY: Check TTL cache (più efficiente della coda)
                dedup_key = (call_id, event, by_user_id)
                if dedup_key in _call_event_dedup_cache:
                    cache_ts = _call_event_dedup_cache[dedup_key]
                    age = now_ts - cache_ts
                    if age < _CALL_EVENT_DEDUP_TTL_SECONDS:
                        dedup_hit = True
                        log_debug(
                            f"C2-NOTIFY: call_event duplicato (TTL cache): "
                            f"call_id={call_id}, event={event}, by_user_id={by_user_id}, "
                            f"recipient={recipient_user_id}, age={age:.1f}s"
                        )
                        return {
                            "status": "duplicate",
                            "message": "Call event notification already processed (TTL dedup)",
                            "dedup_hit": True,
                            "call_id": call_id,
                            "event": event,
                        }
                
                # C2-NOTIFY: Check coda locale (fallback)
                for existing in queue:
                    existing_notification_data = existing.data if isinstance(existing.data, dict) else {}
                    existing_event_data = existing_notification_data.get('data', {}) if isinstance(existing_notification_data.get('data'), dict) else {}
                    existing_call_id = existing_event_data.get('call_id')
                    existing_event = existing_event_data.get('event')
                    existing_by_user_id = existing_event_data.get('by_user_id')
                    
                    if (existing_event_data.get('type') == 'call_event' and
                        existing_call_id == call_id and
                        existing_event == event and
                        existing_by_user_id == by_user_id):
                        dedup_hit = True
                        log_debug(
                            f"C2-NOTIFY: call_event duplicato (queue): "
                            f"call_id={call_id}, event={event}, by_user_id={by_user_id}, "
                            f"recipient={recipient_user_id}"
                        )
                        return {
                            "status": "duplicate",
                            "message": "Call event notification already queued",
                            "notification_id": existing.id,
                            "dedup_hit": True,
                            "call_id": call_id,
                            "event": event,
                        }
                
                # C2-NOTIFY: Aggiungi a cache TTL (dopo check, prima di append)
                _call_event_dedup_cache[dedup_key] = now_ts
        
        # C4-B: Deduplicazione per group_call_event con TTL cache: (room_id, event, by_user_id, target_user_id)
        if data_type == 'group_call_event':
            room_id = event_data.get('room_id')
            event = event_data.get('event')
            by_user_id = event_data.get('by_user_id')
            target_user_id = event_data.get('target_user_id')
            
            if room_id and event:
                # C4-B: Cleanup cache TTL (rimuovi entry più vecchie di TTL)
                now_ts = time.time()
                expired_keys = [
                    key for key, ts in _group_call_event_dedup_cache.items()
                    if (now_ts - ts) > _GROUP_CALL_EVENT_DEDUP_TTL_SECONDS
                ]
                for key in expired_keys:
                    _group_call_event_dedup_cache.pop(key, None)
                
                # C4-B: Check TTL cache (più efficiente della coda)
                dedup_key = (room_id, event, by_user_id, target_user_id)
                if dedup_key in _group_call_event_dedup_cache:
                    cache_ts = _group_call_event_dedup_cache[dedup_key]
                    age = now_ts - cache_ts
                    if age < _GROUP_CALL_EVENT_DEDUP_TTL_SECONDS:
                        dedup_hit = True
                        log_debug(
                            f"C4-B: group_call_event duplicato (TTL cache): "
                            f"room_id={room_id}, event={event}, by_user_id={by_user_id}, "
                            f"target_user_id={target_user_id}, recipient={recipient_user_id}, age={age:.1f}s"
                        )
                        return {
                            "status": "duplicate",
                            "message": "Group call event notification already processed (TTL dedup)",
                            "dedup_hit": True,
                            "room_id": room_id,
                            "event": event,
                        }
                
                # C4-B: Check coda locale (fallback)
                for existing in queue:
                    existing_notification_data = existing.data if isinstance(existing.data, dict) else {}
                    existing_event_data = existing_notification_data.get('data', {}) if isinstance(existing_notification_data.get('data'), dict) else {}
                    existing_room_id = existing_event_data.get('room_id')
                    existing_event = existing_event_data.get('event')
                    existing_by_user_id = existing_event_data.get('by_user_id')
                    existing_target_user_id = existing_event_data.get('target_user_id')
                    
                    if (existing_event_data.get('type') == 'group_call_event' and
                        existing_room_id == room_id and
                        existing_event == event and
                        existing_by_user_id == by_user_id and
                        existing_target_user_id == target_user_id):
                        dedup_hit = True
                        log_debug(
                            f"C4-B: group_call_event duplicato (queue): "
                            f"room_id={room_id}, event={event}, by_user_id={by_user_id}, "
                            f"target_user_id={target_user_id}, recipient={recipient_user_id}"
                        )
                        return {
                            "status": "duplicate",
                            "message": "Group call event notification already queued",
                            "notification_id": existing.id,
                            "dedup_hit": True,
                            "room_id": room_id,
                            "event": event,
                        }
                
                # C4-B: Aggiungi a cache TTL (dopo check, prima di append)
                _group_call_event_dedup_cache[dedup_key] = now_ts

        queue.append(notification)
        log_debug(f"Notifica {notification.id} accodata per {recipient_user_id}. Totale coda: {len(queue)} (message_id={message_id})")
        # 🚀 FIX: Log sempre visibile per debug
        print("")
        print("=" * 80)
        print("✅ SERVER NOTIFY - NOTIFICA SALVATA NELLA CODA")
        print("=" * 80)
        print(f"✅ Notification ID: {notification.id}")
        print(f"✅ Recipient User ID: {recipient_user_id}")
        print(f"✅ Message ID: {message_id}")
        print(f"✅ Tipo: {notification.notification_type}")
        print(f"✅ Totale notifiche in coda per questo utente: {len(queue)}")
        print(f"✅ Timestamp: {notification.timestamp}")
        print(f"✅ Totale notifiche in memoria per tutti gli utenti: {sum(len(q) for q in notifications.values())}")
        print(f"✅ Utenti con notifiche in coda: {list(notifications.keys())}")
        print(f"✅ Numero notifiche per utente: {[(uid, len(q)) for uid, q in notifications.items()]}")
        print("=" * 80)
        print("")

        # Calcola il conteggio delle notifiche non ancora consegnate (badge)
        # Considera le notifiche non consegnate se:
        # 1. delivered=False E (non ha delivered_to_devices O delivered_to_devices è vuoto)
        # 2. Oppure ha delivered_to_devices ma non è stata consegnata a tutti i dispositivi dell'utente
        recipient_devices_count = len(user_to_devices.get(recipient_user_id, set()))
        fallback_unread = sum(
            1 for notif in notifications[recipient_user_id]
            if not (notif.delivered or
                   (hasattr(notif, 'delivered_to_devices') and 
                    notif.delivered_to_devices and 
                    recipient_devices_count > 0 and
                    len(notif.delivered_to_devices) >= recipient_devices_count))
        )
        backend_unread = await fetch_backend_unread_count(recipient_user_id)
        badge_count = backend_unread if backend_unread is not None else fallback_unread
        badge_count = max(int(badge_count), 0)
        notification.data["badge"] = badge_count
        log_debug(f"Badge per {recipient_user_id}: backend={backend_unread}, fallback={fallback_unread}, finale={badge_count}")
        print(
            "🔢 Badge calcolato:"
            f" user_id={recipient_user_id} backend={backend_unread} fallback_queue={fallback_unread} -> badge={badge_count}"
        )
        
        print("")
        print("=" * 80)
        print("🔍 SERVER NOTIFY - VERIFICA DISPOSITIVI DESTINATARI")
        print("=" * 80)
        print(f"🔍 Recipient User ID: {recipient_user_id}")
        print(f"🔍 Dispositivi trovati: {len(recipient_devices)}")
        for i, dev in enumerate(recipient_devices):
            print(f"🔍   Device {i+1}:")
            print(f"🔍     Token: {dev.device_token[:30]}...")
            print(f"🔍     User ID: {dev.user_id}")
            print(f"🔍     Platform: {dev.platform}")
            print(f"🔍     WebSocket: {'✅ CONNESSO' if dev.websocket else '❌ NON CONNESSO'}")
            print(f"🔍     APNs Token: {'✅ PRESENTE' if dev.apns_token else '❌ ASSENTE'}")
            print(f"🔍     Last Seen: {dev.last_seen}")
        print("=" * 80)
        print("")
        
        # 🔔 CORREZIONE: Verifica se il messaggio è già stato letto PRIMA di inviare via WebSocket
        # Questo evita di mostrare toast per messaggi già letti anche quando la notifica arriva via WebSocket
        should_send_websocket = True
        if notification_data.notification_type == NotificationType.MESSAGE:
            message_data = notification_data.data if isinstance(notification_data.data, dict) else {}
            message_id = message_data.get('message_id')
            chat_id = message_data.get('chat_id')
            
            if message_id and chat_id:
                try:
                    import requests
                    check_url = f"{BACKEND_BASE_URL}/api/chats/{chat_id}/messages/{message_id}/is-read/"
                    headers = {}
                    if SERVICE_AUTH_KEY:
                        headers["X-Notify-Service-Key"] = SERVICE_AUTH_KEY
                    
                    print(f"🔔 SERVER NOTIFY (WebSocket) - Verifica stato lettura: chat_id={chat_id}, message_id={message_id}, user_id={recipient_user_id}")
                    response = requests.get(
                        check_url,
                        headers=headers,
                        params={"user_id": recipient_user_id},
                        timeout=5
                    )
                    
                    print(f"🔔 SERVER NOTIFY (WebSocket) - Risposta API: status={response.status_code}")
                    if response.status_code == 200:
                        result = response.json()
                        is_read = result.get('is_read', False)
                        print(f"🔔 SERVER NOTIFY (WebSocket) - Messaggio {message_id} letto: {is_read}")
                        if is_read:
                            print(f"🔔 SERVER NOTIFY (WebSocket) - ❌ Notifica {notification.id} saltata: messaggio {message_id} già letto dall'utente {recipient_user_id}")
                            should_send_websocket = False
                        else:
                            print(f"🔔 SERVER NOTIFY (WebSocket) - ✅ Messaggio {message_id} non letto, procedo con WebSocket")
                    else:
                        print(f"⚠️ SERVER NOTIFY (WebSocket) - Errore API: status={response.status_code}, body={response.text}")
                        # In caso di errore API (non timeout/connection), procedo comunque per non bloccare le notifiche
                        print(f"🔔 SERVER NOTIFY (WebSocket) - ⚠️ Errore verifica stato lettura, procedo comunque con WebSocket")
                except requests.exceptions.Timeout:
                    print(f"⚠️ SERVER NOTIFY (WebSocket) - Timeout verifica stato lettura messaggio {message_id}, procedo comunque con WebSocket")
                    # In caso di timeout, procedo comunque per non bloccare le notifiche
                except requests.exceptions.ConnectionError:
                    print(f"⚠️ SERVER NOTIFY (WebSocket) - Errore connessione verifica stato lettura messaggio {message_id}, procedo comunque con WebSocket")
                    # In caso di errore di connessione, procedo comunque per non bloccare le notifiche
                except Exception as e:
                    # In caso di altri errori, procedo comunque per non bloccare le notifiche
                    print(f"⚠️ SERVER NOTIFY (WebSocket) - Errore verifica stato lettura messaggio {message_id}: {e}")
                    print(f"🔔 SERVER NOTIFY (WebSocket) - ⚠️ Errore verifica stato lettura, procedo comunque con WebSocket")
        
        # Invia anche tramite WebSocket se disponibile E se il messaggio non è già letto
        if should_send_websocket:
            notification_data_ws = {
                "type": "notification" if notification_data.notification_type != NotificationType.CHAT_DELETED else "chat_deleted",
                "id": notification.id,
                "title": notification.title,
                "body": notification.body,
                "data": notification.data,
                "timestamp": notification.timestamp,
                "notification_type": notification.notification_type.value,
                "badge": badge_count,
            }
            websocket_devices = [device for device in recipient_devices if device.websocket]
            websocket_active = bool(websocket_devices)
            
            # C2-NOTIFY: Logging strutturato per call_event (dopo dedup, prima routing)
            if data_type == 'call_event' and call_id and event:
                delivery_channel = 'ws' if websocket_active else 'push'
                log_message = (
                    f"C2-NOTIFY: call_event processed | "
                    f"call_id={call_id} | event={event} | "
                    f"recipient_user_id={recipient_user_id} | "
                    f"delivery_channel={delivery_channel} | "
                    f"dedup_hit={dedup_hit} | "
                    f"ws_active={websocket_active} | "
                    f"ws_devices={len(websocket_devices)} | "
                    f"by_user_id={by_user_id or 'server'}"
                )
                log_debug(log_message)
                print(f"📞 C2-NOTIFY: call_event={event}, call_id={call_id}, "
                      f"recipient={recipient_user_id}, channel={delivery_channel}, "
                      f"dedup={dedup_hit}, ws_active={websocket_active}")
                
                # C2-NOTIFY: Safety rule - event != "incoming" NON deve aprire UI incoming
                # Questo è già gestito dal client Flutter, ma loggiamo per audit
                if event != 'incoming':
                    log_debug(
                        f"C2-NOTIFY: non-incoming event ({event}) - "
                        f"client will NOT open incoming UI (event update only)"
                    )
            
            # C4-B: Logging strutturato per group_call_event (dopo dedup, prima routing)
            if data_type == 'group_call_event':
                room_id = event_data.get('room_id')
                event = event_data.get('event')
                by_user_id = event_data.get('by_user_id')
                target_user_id = event_data.get('target_user_id')
                
                if room_id and event:
                    delivery_channel = 'ws' if websocket_active else 'push'
                    log_message = (
                        f"C4-B: group_call_event processed | "
                        f"room_id={room_id} | event={event} | "
                        f"recipient_user_id={recipient_user_id} | "
                        f"delivery_channel={delivery_channel} | "
                        f"dedup_hit={dedup_hit} | "
                        f"ws_active={websocket_active} | "
                        f"ws_devices={len(websocket_devices)} | "
                        f"by_user_id={by_user_id or 'server'} | "
                        f"target_user_id={target_user_id or 'broadcast'}"
                    )
                    log_debug(log_message)
                    print(f"📞 C4-B: group_call_event={event}, room_id={room_id}, "
                          f"recipient={recipient_user_id}, channel={delivery_channel}, "
                          f"dedup={dedup_hit}, ws_active={websocket_active}, "
                          f"target={target_user_id or 'broadcast'}")
                    
                    # C4-B: Routing rule - incoming events use push if offline, ws if online
                    # Other events (joined/left/ended/missed/signal_available) prefer ws, push only if offline
                    if event == 'incoming':
                        log_debug(
                            f"C4-B: incoming event - will use push if offline, ws if online"
                        )
                    else:
                        log_debug(
                            f"C4-B: non-incoming event ({event}) - will use ws if online, push if offline"
                        )
            
            # FIX_QG5_P0: Decisione chiara su come inviare la notifica
            # Il Notify Server è l'unica source of truth per stato WebSocket
            notification_type_str = notification_data.notification_type.value if hasattr(notification_data.notification_type, 'value') else str(notification_data.notification_type)
            
            print("")
            print("=" * 80)
            print("🎯 FIX_QG5_P0 - DECISIONE INVIO NOTIFICA")
            print("=" * 80)
            print(f"🎯 User ID: {recipient_user_id}")
            print(f"🎯 Notification Type: {notification_type_str}")
            print(f"🎯 WebSocket Attivo: {'✅ SÌ' if websocket_active else '❌ NO'}")
            print(f"🎯 Device con WebSocket: {len(websocket_devices)}")
            print(f"🎯 Totale dispositivi: {len(recipient_devices)}")
            print("=" * 80)
            print("")
            
            print(
                "📡 Stato WebSocket destinatario: "
                f"user_id={recipient_user_id} "
                f"active={websocket_active} (device attivi: {len(websocket_devices)})"
            )
            
            # 🚀 FIX: Log dettagliato per diagnosticare problemi
            if not websocket_active:
                print("")
                print("=" * 80)
                print("⚠️ SERVER NOTIFY - NESSUN WEBSOCKET ATTIVO PER DESTINATARIO")
                print("=" * 80)
                print(f"⚠️ User ID: {recipient_user_id}")
                print(f"⚠️ Totale dispositivi registrati: {len(recipient_devices)}")
                for i, dev in enumerate(recipient_devices):
                    print(f"   Device {i+1}:")
                    print(f"     - Token: {dev.device_token[:30]}...")
                    print(f"     - WebSocket: {'✅ ATTIVO' if dev.websocket else '❌ NON ATTIVO'}")
                    print(f"     - Is Online: {dev.is_online}")
                    print(f"     - Last Seen: {dev.last_seen}")
                print("=" * 80)
                print("")
            
            if websocket_active:
                # FIX_QG5_P0: DECISION: WS_ONLY
                # WebSocket è attivo, invio via WebSocket per real-time
                # APNs/FCM verrà inviato comunque dopo per garantire notifiche in background/terminated
                print("")
                print("=" * 80)
                print("🎯 DECISION: WS_ONLY (WebSocket attivo, invio real-time)")
                print("=" * 80)
                print(f"📡 User ID: {recipient_user_id}")
                print(f"📡 Device attivi: {len(websocket_devices)}")
                print(f"📡 Notification ID: {notification.id}")
                print(f"📡 Type: {notification_data_ws.get('type')}")
                print(f"📡 Message ID: {notification_data_ws.get('data', {}).get('message_id', 'N/A')}")
                print(f"📡 Chat ID: {notification_data_ws.get('data', {}).get('chat_id', 'N/A')}")
                print(f"📡 Content: {str(notification_data_ws.get('data', {}).get('content', 'N/A'))[:100]}")
                print(f"📡 Sender: {notification_data_ws.get('data', {}).get('sender_name', 'N/A')}")
                print(f"📡 Badge: {badge_count}")
                print(f"📡 Timestamp: {notification_data_ws.get('timestamp', 'N/A')}")
                print("=" * 80)
                print("")
                log_debug(f"DECISION: WS_ONLY -> {recipient_user_id}: {notification_data_ws}")
                # OBSERVABILITY B1: Passa correlation_id a send_websocket_notification
                delivered_ws = await send_websocket_notification(recipient_user_id, notification_data_ws, correlation_id=correlation_id)
                print("")
                print("=" * 80)
                print(f"{'✅' if delivered_ws else '❌'} SERVER NOTIFY - WebSocket {'INVIATO' if delivered_ws else 'NON INVIATO'}")
                print("=" * 80)
                print(f"📡 User ID: {recipient_user_id}")
                print(f"📡 Delivered: {delivered_ws}")
                print(f"📡 Message ID: {notification_data_ws.get('data', {}).get('message_id', 'N/A')}")
                print(f"📡 Chat ID: {notification_data_ws.get('data', {}).get('chat_id', 'N/A')}")
                if not delivered_ws:
                    print(f"❌ MOTIVO: Nessun WebSocket attivo per questo utente")
                    print(f"❌ Device registrati: {len(user_to_devices.get(recipient_user_id, set()))}")
                    print(f"❌ Device con WebSocket: {sum(1 for token in user_to_devices.get(recipient_user_id, set()) if devices.get(token) and devices.get(token).websocket)}")
                print("=" * 80)
                print("")
            else:
                # FIX_QG5_P0: DECISION: APNS_NO_WS
                # WebSocket non attivo, invio solo via APNs/FCM
                print("")
                print("=" * 80)
                print("🎯 DECISION: APNS_NO_WS (WebSocket non attivo, invio solo push)")
                print("=" * 80)
                print(f"⚠️ User ID: {recipient_user_id}")
                print(f"⚠️ Nessun WebSocket attivo per questo utente")
                print(f"⚠️ Proseguo con invio APNs/FCM")
                print("=" * 80)
                print("")
                log_debug(f"DECISION: APNS_NO_WS -> {recipient_user_id}, nessun WebSocket attivo")
        else:
            print(f"🔔 SERVER NOTIFY (WebSocket) - Invio WebSocket saltato: messaggio già letto")

        # FIX_QG5_P0: Invio APNs per dispositivi iOS registrati
        # Logica decisionale:
        # - WS attivo + app foreground → WS_ONLY (ma inviamo APNs per garantire background/terminated)
        # - WS attivo + app background → DECISION: APNS_BACKGROUND (APNs necessario)
        # - WS non attivo → DECISION: APNS_NO_WS (solo APNs)
        # Nota: Non possiamo sapere con certezza se l'app è in foreground/background,
        # quindi inviamo sempre APNs se disponibile per garantire copertura completa
        notification.data["delivered_via_apns"] = False
        apns_sent_any = False
        missing_apns: List[str] = []
        apns_tokens_sent: Set[str] = set()
        sent_stats = {"ios": 0, "android": 0}
        failed_stats = {"ios": 0, "android": 0}
        error_list: List[Dict[str, str]] = []

        for device in recipient_devices:
            if device.platform.lower() != "ios":
                continue
            # FIX_QG5_P0: Invia APNs anche se WebSocket è attivo
            # Questo garantisce notifiche quando l'app è in background o terminated
            # WebSocket funziona solo in foreground, APNs funziona sempre
            # DECISION: Se WS attivo → APNS_BACKGROUND (per garantire copertura)
            # DECISION: Se WS non attivo → APNS_NO_WS (già loggato sopra)
            if not device.apns_token:
                missing_apns.append(device.device_token[:20])
                continue

            sanitized_token = sanitize_apns_token(device.apns_token)
            if sanitized_token in apns_tokens_sent:
                log_debug(f"APNs deduplicato per user {device.user_id} token={sanitized_token[:12]}...")
                continue

            apns_tokens_sent.add(sanitized_token)
            # FIX_QG5_P0: Log decisionale chiaro per APNs
            decision_reason = "APNS_BACKGROUND" if device.websocket else "APNS_NO_WS"
            
            print("")
            print("=" * 80)
            print(f"🎯 DECISION: {decision_reason} (Invio APNs per iOS)")
            print("=" * 80)
            print(f"📬 User ID: {device.user_id}")
            print(f"📬 Device Token: {device.apns_token[:30]}...")
            print(f"📬 Platform: {device.platform}")
            print(f"📬 Environment: {device.apns_environment or ('sandbox' if APNS_USE_SANDBOX else 'production')}")
            print(f"📬 Topic: {device.apns_topic or APNS_TOPIC}")
            print(f"📬 Title: {notification.title}")
            print(f"📬 Body: {notification.body}")
            print(f"📬 Sound: {notification.data.get('sound', APNS_DEFAULT_SOUND)}")
            print(f"📬 Badge: {badge_count}")
            print(f"📬 WebSocket Attivo: {'✅ SÌ' if device.websocket else '❌ NO'}")
            print(f"📬 Reason: {decision_reason}")
            print("=" * 80)
            print("")
            notification.data["delivered_via_apns"] = True
            notification.data.setdefault("apns_environment", device.apns_environment)
            apns_sent = await push_via_apns(device, notification)
            if apns_sent:
                apns_sent_any = True
                sent_stats["ios"] += 1
                print(f"✅ APNs - Notifica inviata a {device.user_id}")
                # OBSERVABILITY B2: Metriche push success
                if 'notify_metrics' in globals():
                    notify_metrics.increment_counter(
                        'push_send_total',
                        labels={
                            'channel': 'apns',
                            'status': 'success',
                            'notification_type': notification.notification_type.value
                        }
                    )
            else:
                failed_stats["ios"] += 1
                error_reason = "APNs send failed"
                error_list.append({
                    "platform": "ios",
                    "token_prefix": device.apns_token[:10] + "..." if device.apns_token else "N/A",
                    "reason": error_reason
                })
                # OBSERVABILITY B2: Metriche push fail
                if 'notify_metrics' in globals():
                    notify_metrics.increment_counter(
                        'push_send_total',
                        labels={
                            'channel': 'apns',
                            'status': 'fail',
                            'notification_type': notification.notification_type.value
                        }
                    )
                    notify_metrics.increment_counter(
                        'push_send_fail_total',
                        labels={'channel': 'apns', 'error_type': 'send_failed'}
                    )
                print(
                    f"⚠️ APNs - Invio fallito per {device.user_id}, "
                    "resterà disponibile via polling/WebSocket"
                )
                log_debug(f"APNs fallito per device {device.device_token[:12]}... user {device.user_id}")

        if not apns_sent_any:
            notification.data["delivered_via_apns"] = False
        if missing_apns:
            print(f"⚠️ APNs - {len(missing_apns)} dispositivi iOS senza token (es. {missing_apns[0]}...), push saltata")
        
        # Invio FCM per dispositivi Android registrati
        notification.data["delivered_via_fcm"] = False
        fcm_sent_any = False
        missing_fcm: List[str] = []
        fcm_tokens_sent: Set[str] = set()

        for device in recipient_devices:
            if device.platform.lower() != "android":
                continue
            if not device.fcm_token:
                missing_fcm.append(device.device_token[:20])
                continue

            if device.fcm_token in fcm_tokens_sent:
                log_debug(f"FCM deduplicato per user {device.user_id} token={device.fcm_token[:12]}...")
                continue

            fcm_tokens_sent.add(device.fcm_token)
            
            # FIX_QG5_P0: Log decisionale chiaro per FCM
            decision_reason = "APNS_BACKGROUND" if device.websocket else "APNS_NO_WS"
            
            print("")
            print("=" * 80)
            print(f"🎯 DECISION: {decision_reason} (Invio FCM per Android)")
            print("=" * 80)
            print(f"🔥 User ID: {device.user_id}")
            print(f"🔥 FCM Token: {device.fcm_token[:30]}...")
            print(f"🔥 Platform: {device.platform}")
            print(f"🔥 Title: {notification.title}")
            print(f"🔥 Body: {notification.body}")
            print(f"🔥 Device ID: {device.device_id or 'N/A'}")
            print(f"🔥 WebSocket Attivo: {'✅ SÌ' if device.websocket else '❌ NO'}")
            print(f"🔥 Reason: {decision_reason}")
            print("=" * 80)
            print("")
            notification.data["delivered_via_fcm"] = True
            fcm_sent = await push_via_fcm(device, notification)
            if fcm_sent:
                fcm_sent_any = True
                sent_stats["android"] += 1
                print(f"✅ FCM - Notifica inviata a {device.user_id}")
                # OBSERVABILITY B2: Metriche push success
                if 'notify_metrics' in globals():
                    notify_metrics.increment_counter(
                        'push_send_total',
                        labels={
                            'channel': 'fcm',
                            'status': 'success',
                            'notification_type': notification.notification_type.value
                        }
                    )
            else:
                failed_stats["android"] += 1
                error_reason = "FCM send failed"
                error_list.append({
                    "platform": "android",
                    "token_prefix": device.fcm_token[:10] + "..." if device.fcm_token else "N/A",
                    "reason": error_reason
                })
                # OBSERVABILITY B2: Metriche push fail
                if 'notify_metrics' in globals():
                    notify_metrics.increment_counter(
                        'push_send_total',
                        labels={
                            'channel': 'fcm',
                            'status': 'fail',
                            'notification_type': notification.notification_type.value
                        }
                    )
                    notify_metrics.increment_counter(
                        'push_send_fail_total',
                        labels={'channel': 'fcm', 'error_type': 'send_failed'}
                    )
                print(
                    f"⚠️ FCM - Invio fallito per {device.user_id}, "
                    "resterà disponibile via polling/WebSocket"
                )
                log_debug(f"FCM fallito per device {device.device_token[:12]}... user {device.user_id}")

        if not fcm_sent_any:
            notification.data["delivered_via_fcm"] = False
        if missing_fcm:
            print(f"⚠️ FCM - {len(missing_fcm)} dispositivi Android senza token (es. {missing_fcm[0]}...), push saltata")
        
        print(f"📤 Notifica inviata a {notification_data.recipient_id}: {notification_data.title}")
        print(f"📤 Tipo: {notification_data.notification_type}")
        print(f"📤 Contenuto: {notification_data.body}")
        log_debug(f"Invio completato per {recipient_user_id}: badge={badge_count}, websocket_active={websocket_active}, apns_sent={apns_sent_any}")
        
        # Pulisci notifiche vecchie
        cleanup_old_notifications()
        
        return {
            "status": "success",
            "recipient_id": recipient_user_id,
            "sent": sent_stats,
            "failed": failed_stats,
            "errors": error_list,
            "notification_id": notification.id
        }
        
    except Exception as e:
        print(f"❌ Errore nell'invio notifica: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/badge-sync")
async def badge_sync(sync_data: BadgeSyncRequest, request: Request):
    """Sincronizza badge/toast tra i dispositivi dell'utente senza mostrare push del sistema operativo."""
    try:
        if SERVICE_AUTH_KEY:
            provided_key = (
                request.headers.get("X-Notify-Service-Key")
                or request.headers.get("X-Service-Key")
                or request.headers.get("Authorization")
            )
            normalized = provided_key.replace("Token ", "").strip() if provided_key else ""
            if normalized != SERVICE_AUTH_KEY:
                raise HTTPException(status_code=401, detail="Unauthorized")

        user_id = str(sync_data.user_id)
        total_unread = max(int(sync_data.total_unread), 0)
        chat_unread = max(int(sync_data.chat_unread or 0), 0)
        read_message_ids = [str(mid) for mid in (sync_data.read_message_ids or [])]
        event_timestamp = sync_data.timestamp or datetime.utcnow().isoformat()
        log_debug(f"/badge-sync -> user={user_id}, total_unread={total_unread}, chat_unread={chat_unread}, ids={read_message_ids}, source={sync_data.source}")

        payload = {
            "type": "badge_sync",
            "total_unread": total_unread,
            "chat_unread": chat_unread,
            "chat_id": sync_data.chat_id,
            "read_message_ids": read_message_ids,
            "source": sync_data.source or "system",
            "timestamp": event_timestamp,
            "badge": total_unread,
        }

        notification = Notification(
            id=generate_notification_id(),
            recipient_id=user_id,
            title="",
            body="",
            data=payload.copy(),
            sender_id=payload["source"],
            timestamp=time.time(),
            notification_type=NotificationType.BADGE_SYNC,
            delivered=False,
        )
        notifications.setdefault(user_id, []).append(notification)
        log_debug(f"Coda badge-sync utente {user_id}: lunghezza={len(notifications[user_id])}")

        websocket_payload = {
            "type": "badge_sync",
            "id": notification.id,
            "data": payload,
            "timestamp": notification.timestamp,
            "notification_type": NotificationType.BADGE_SYNC.value,
        }
        delivered_ws = await send_websocket_notification(user_id, websocket_payload)
        log_debug(f"badge-sync inviato via WebSocket? {delivered_ws} -> payload={websocket_payload}")
        cleanup_old_notifications()

        return {
            "status": "success",
            "notification_id": notification.id,
            "delivered_ws": delivered_ws,
        }
    except Exception as exc:
        print(f"❌ Errore badge sync: {exc}")
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/call/start")
async def start_call(call_data: CallRequest):
    """Inizia una chiamata audio o video"""
    try:
        call_id = call_data.call_id or generate_call_id()
        
        # Verifica che il destinatario sia online
        recipient_device = None
        for device in devices.values():
            if device.user_id == call_data.recipient_id:
                recipient_device = device
                break
        
        if not recipient_device:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Destinatario non trovato o offline"
            )
        
        # Crea la chiamata
        call_info = {
            "call_id": call_id,
            "sender_id": call_data.sender_id,
            "recipient_id": call_data.recipient_id,
            "call_type": call_data.call_type,
            "is_group": call_data.is_group,
            "group_members": call_data.group_members or [],
            "status": CallStatus.INCOMING,
            "start_time": time.time(),
            "end_time": None,
            "duration": None,
            "webrtc_session": None,  # Verrà impostato quando la chiamata viene accettata
            "ice_servers": None,     # Verrà impostato dal server WebRTC
            "janus_room_id": None    # ID della stanza Janus per WebRTC
        }
        
        active_calls[call_id] = call_info
        
        # Crea notifica di chiamata con informazioni WebRTC
        call_title = f"Chiamata {call_data.call_type}" if call_data.call_type == "audio" else f"Videochiamata"
        if call_data.is_group:
            call_title = f"Chiamata di gruppo {call_data.call_type}"
        
        notification = Notification(
            id=generate_notification_id(),
            recipient_id=call_data.recipient_id,
            title=call_title,
            body=f"Chiamata in arrivo da {call_data.sender_id}",
            data={
                "call_id": call_id,
                "call_type": call_data.call_type,
                "is_group": call_data.is_group,
                "group_members": call_data.group_members or [],
                "sender_id": call_data.sender_id,
                "timestamp": time.time(),
                "priority": "high"  # Alta priorità per le chiamate
            },
            sender_id=call_data.sender_id,
            timestamp=time.time(),
            notification_type=NotificationType.CALL if call_data.call_type == "audio" else NotificationType.VIDEO_CALL,
            call_status=CallStatus.INCOMING,
            delivered=False
        )
        
        # Aggiungi alla coda notifiche
        if call_data.recipient_id not in notifications:
            notifications[call_data.recipient_id] = []
        notifications[call_data.recipient_id].append(notification)
        
        # Invia tramite WebSocket con priorità alta
        call_notification = {
            "type": "call",
            "call_id": call_id,
            "call_type": call_data.call_type,
            "is_group": call_data.is_group,
            "sender_id": call_data.sender_id,
            "recipient_id": call_data.recipient_id,
            "status": CallStatus.INCOMING.value,
            "timestamp": time.time(),
            "priority": "high",
            "timeout": 30  # Timeout chiamata in secondi
        }
        await send_websocket_notification(call_data.recipient_id, call_notification)
        
        # Programma timeout automatico per chiamata non risposta
        asyncio.create_task(auto_timeout_call(call_id, 30))
        
        print(f"📞 Chiamata {call_data.call_type} iniziata: {call_id}")
        print(f"📞 Da: {call_data.sender_id} a: {call_data.recipient_id}")
        
        return CallResponse(
            call_id=call_id,
            status=CallStatus.INCOMING,
            message="Chiamata inviata"
        )
        
    except Exception as e:
        print(f"❌ Errore nell'inizio chiamata: {e}")
        raise HTTPException(status_code=500, detail=str(e))

class CallAnswerRequest(BaseModel):
    user_id: str
    auth_token: Optional[str] = None

@app.post("/call/answer/{call_id}")
async def answer_call(call_id: str, request_data: CallAnswerRequest):
    """Risponde a una chiamata e crea sessione WebRTC"""
    try:
        if call_id not in active_calls:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Chiamata non trovata"
            )
        
        call_info = active_calls[call_id]
        
        # Verifica che l'utente sia autorizzato a rispondere
        if call_info["recipient_id"] != request_data.user_id:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Non autorizzato a rispondere a questa chiamata"
            )
        
        call_info["status"] = CallStatus.ANSWERED
        call_info["answer_time"] = time.time()
        
        # Integra con server WebRTC per creare sessione
        webrtc_session = await integrate_with_webrtc_server(
            call_id, 
            "create_session", 
            {
                "recipient_id": call_info["recipient_id"],
                "call_type": call_info["call_type"],
                "auth_token": request_data.auth_token
            }
        )
        
        if webrtc_session:
            call_info["webrtc_session"] = webrtc_session
            call_info["janus_room_id"] = webrtc_session.get("room_id")
            call_info["ice_servers"] = webrtc_session.get("ice_servers")
        
        # Notifica il chiamante con informazioni WebRTC
        caller_notification = {
            "type": "call_status",
            "call_id": call_id,
            "status": CallStatus.ANSWERED.value,
            "webrtc_session": webrtc_session,
            "timestamp": time.time()
        }
        await send_websocket_notification(call_info["sender_id"], caller_notification)
        
        # Notifica anche il destinatario (per conferma)
        recipient_notification = {
            "type": "call_answered",
            "call_id": call_id,
            "webrtc_session": webrtc_session,
            "timestamp": time.time()
        }
        await send_websocket_notification(call_info["recipient_id"], recipient_notification)
        
        print(f"📞 Chiamata {call_id} risposta da {request_data.user_id}")
        if webrtc_session:
            print(f"📞 Sessione WebRTC creata: {webrtc_session.get('session_id')}")
        
        return CallResponse(
            call_id=call_id,
            status=CallStatus.ANSWERED,
            message="Chiamata risposta e sessione WebRTC creata"
        )
        
    except Exception as e:
        print(f"❌ Errore nella risposta chiamata: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/call/reject/{call_id}")
async def reject_call(call_id: str, user_id: str):
    """Rifiuta una chiamata"""
    try:
        if call_id not in active_calls:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Chiamata non trovata"
            )
        
        call_info = active_calls[call_id]
        call_info["status"] = CallStatus.REJECTED
        call_info["end_time"] = time.time()
        call_info["duration"] = int(call_info["end_time"] - call_info["start_time"])
        
        # Notifica il chiamante
        caller_notification = {
            "type": "call_status",
            "call_id": call_id,
            "status": CallStatus.REJECTED.value,
            "timestamp": time.time()
        }
        await send_websocket_notification(call_info["sender_id"], caller_notification)
        
        print(f"📞 Chiamata {call_id} rifiutata da {user_id}")
        
        return CallResponse(
            call_id=call_id,
            status=CallStatus.REJECTED,
            message="Chiamata rifiutata"
        )
        
    except Exception as e:
        print(f"❌ Errore nel rifiuto chiamata: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/call/end/{call_id}")
async def end_call(call_id: str, user_id: str):
    """Termina una chiamata"""
    try:
        if call_id not in active_calls:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.ENDED,
                message="Chiamata non trovata"
            )
        
        call_info = active_calls[call_id]
        call_info["status"] = CallStatus.ENDED
        call_info["end_time"] = time.time()
        call_info["duration"] = int(call_info["end_time"] - call_info["start_time"])
        
        # Notifica tutti i partecipanti
        participants = [call_info["sender_id"], call_info["recipient_id"]]
        if call_info.get("group_members"):
            participants.extend(call_info["group_members"])
        
        for participant in participants:
            if participant != user_id:  # Non notificare chi ha terminato
                end_notification = {
                    "type": "call_status",
                    "call_id": call_id,
                    "status": CallStatus.ENDED.value,
                    "duration": call_info["duration"],
                    "timestamp": time.time()
                }
                await send_websocket_notification(participant, end_notification)
        
        print(f"📞 Chiamata {call_id} terminata da {user_id} (durata: {call_info['duration']}s)")
        
        return CallResponse(
            call_id=call_id,
            status=CallStatus.ENDED,
            message="Chiamata terminata"
        )
        
    except Exception as e:
        print(f"❌ Errore nella terminazione chiamata: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/poll/{device_token}")
async def poll_notifications(device_token: str):
    """Polling per ottenere notifiche per un dispositivo"""
    try:
        # 🚀 FIX: Log ridotto per evitare loop infinito - solo quando necessario
        # print(f"🔄 Polling richiesto per device_token: {device_token[:20]}...")
        
        # 🔧 FALLBACK: Se devices è vuoto, ricarica dal database
        if len(devices) == 0:
            print("⚠️ Dizionario devices vuoto, ricaricamento dal database...")
            load_devices_from_db()
            initialize_mappings()
            print(f"✅ Ricaricati {len(devices)} dispositivi dal database")
        
        # Trova il dispositivo
        device = devices.get(device_token)
        
        # 🔧 FALLBACK: Se dispositivo non trovato, prova a ricaricare dal database
        if not device:
            print(f"⚠️ Dispositivo non trovato in memoria, ricerca nel database...")
            load_devices_from_db()
            initialize_mappings()
            device = devices.get(device_token)
            
            if not device:
                print(f"❌ Dispositivo non trovato: {device_token[:20]}...")
                return {"notifications": [], "status": "device_not_found"}
        
        # Aggiorna last_seen
        device.last_seen = time.time()
        device.is_online = True
        
        # 💾 Aggiorna anche nel database
        save_device_to_db(device)
        
        # Ottieni le notifiche per questo utente
        user_notifications = notifications.get(device.user_id, [])
        
        # 🚀 FIX: Log ridotto - solo quando ci sono notifiche nuove
        
        # Filtra solo notifiche non consegnate a QUESTO dispositivo specifico
        pending_notifications = []
        print(f"🔍 DEBUG - Verifica device_token: {device_token[:30]}... (lunghezza: {len(device_token)})")
        for notif in user_notifications:
            # Inizializza delivered_to_devices se non presente (retrocompatibilità)
            if not hasattr(notif, 'delivered_to_devices') or notif.delivered_to_devices is None:
                notif.delivered_to_devices = set()
            
            # 🚀 FIX: Log ridotto per evitare loop infinito
            delivered_to_set = notif.delivered_to_devices if hasattr(notif, 'delivered_to_devices') else set()
            is_in_delivered = device_token in delivered_to_set
            
            # 🚀 FIX CHAT DETAIL: Considera la notifica come pending se:
            # 1. NON è stata ancora consegnata a questo dispositivo, OPPURE
            # 2. È una notifica di tipo "message" e il messaggio NON è stato ancora letto
            notif_type = getattr(notif, 'notification_type', 'message')
            if hasattr(notif_type, 'value'):
                notif_type = notif_type.value
            elif not isinstance(notif_type, str):
                notif_type = str(notif_type)
            
            is_already_delivered = device_token in notif.delivered_to_devices
            should_include = False
            
            if not is_already_delivered:
                # Non ancora consegnata: includi sempre
                should_include = True
                # 🚀 FIX: Log ridotto per evitare loop infinito
                # print(f"🔔 SERVER NOTIFY - Notifica {notif.id} aggiunta al polling (non ancora consegnata, tipo: {notif_type})")
            elif notif_type == 'message':
                # Già consegnata ma è un messaggio: verifica se è stato letto
                message_data = notif.data if isinstance(notif.data, dict) else {}
                message_id = message_data.get('message_id')
                
                if message_id:
                    chat_id = message_data.get('chat_id')
                    if chat_id:
                        try:
                            import aiohttp
                            backend_url = os.getenv('BACKEND_URL', 'http://securevox-backend:8000')
                            service_key = os.getenv('SERVICE_AUTH_KEY', '')
                            url = f"{backend_url}/api/chats/{chat_id}/messages/{message_id}/is-read/"
                            headers = {}
                            if service_key:
                                headers["X-Notify-Service-Key"] = service_key
                            params = {"user_id": str(device.user_id)}
                            timeout = aiohttp.ClientTimeout(total=2.0)
                            
                            async with aiohttp.ClientSession(timeout=timeout) as session:
                                async with session.get(url, headers=headers, params=params) as response:
                                    if response.status == 200:
                                        result = await response.json()
                                        is_read = result.get('is_read', False)
                                        # 🚀 FIX: Log ridotto per evitare loop infinito
                                        # print(f"🔍 SERVER NOTIFY - Messaggio {message_id} (chat {chat_id}) letto da user {device.user_id}: {is_read}")
                                        if not is_read:
                                            # Messaggio non letto: includi anche se già consegnata
                                            should_include = True
                                    else:
                                        # 🚀 FIX: Log ridotto per evitare loop infinito
                                        # In caso di errore, includi la notifica per sicurezza
                                        should_include = True
                        except Exception as e:
                            # 🚀 FIX: Log ridotto per evitare loop infinito
                            # In caso di errore, includi la notifica per sicurezza
                            should_include = True
            
            if should_include:
                pending_notifications.append(notif)
        
        # 🚀 FIX: Log ridotto per evitare loop infinito - solo quando ci sono notifiche nuove
        # print(f"🔍 Polling - Notifiche non consegnate a questo dispositivo ({device_token[:20]}...): {len(pending_notifications)}")
        
        # 🚀 FIX: Log solo quando ci sono notifiche nuove
        if len(pending_notifications) > 0:
            print(f"📨 Polling - {len(pending_notifications)} notifiche per user {device.user_id}")
        
        # Marca come consegnate a QUESTO dispositivo specifico (non globalmente)
        for notif in pending_notifications:
            if not hasattr(notif, 'delivered_to_devices') or notif.delivered_to_devices is None:
                notif.delivered_to_devices = set()
            notif.delivered_to_devices.add(device_token)
            
            # Marca come delivered globale solo se consegnata a TUTTI i dispositivi dell'utente
            all_user_devices = user_to_devices.get(device.user_id, set())
            if all_user_devices and len(notif.delivered_to_devices) >= len(all_user_devices):
                notif.delivered = True
        
        # Converti in formato JSON
        notifications_data = []
        for notif in pending_notifications:
            # 🆕 Converti notification_type da Enum a stringa se necessario
            notif_type = getattr(notif, 'notification_type', 'message')
            if hasattr(notif_type, 'value'):
                notif_type = notif_type.value
            elif not isinstance(notif_type, str):
                notif_type = str(notif_type)
            
            # 🚀 FIX: Log ridotto per evitare loop infinito - solo quando necessario
            # 🐛 DEBUG: Estrai dati del messaggio per log dettagliato
            message_data = notif.data if isinstance(notif.data, dict) else {}
            chat_id = message_data.get('chat_id', 'N/A')
            message_id = message_data.get('message_id', 'N/A')
            
            # 🚀 FIX: Log dettagliato solo per messaggi nuovi (non già consegnati)
            if notif_type == 'message' and message_id != 'N/A':
                print(f"📨 Polling - Messaggio {message_id} (chat {chat_id}) per user {device.user_id}")
            
            # 🔔 CORREZIONE: Assicurati che il badge sia sempre incluso nel payload
            notif_data = notif.data if isinstance(notif.data, dict) else {}
            badge_value = notif_data.get("badge")
            
            notification_json = {
                "id": notif.id,
                "title": notif.title,
                "body": notif.body,
                "data": notif.data,
                "timestamp": notif.timestamp,
                "sender_id": notif.sender_id,
                "notification_type": notif_type,  # 🆕 Aggiungi notification_type
                "type": notif_type,  # 🆕 Compatibilità con 'type'
                "badge": badge_value,  # 🔔 Assicura che il badge sia sempre incluso a livello root
            }
            notifications_data.append(notification_json)
        
        if pending_notifications:
            # Rimuovi solo le notifiche consegnate a TUTTI i dispositivi dell'utente
            all_user_devices = user_to_devices.get(device.user_id, set())
            notifications[device.user_id] = [
                notif for notif in user_notifications
                if not (notif.delivered or
                       (hasattr(notif, 'delivered_to_devices') and 
                        notif.delivered_to_devices and 
                        all_user_devices and
                        len(notif.delivered_to_devices) >= len(all_user_devices)))
            ]
            cleanup_old_notifications()
        
        # 🚀 FIX: Log solo quando ci sono notifiche da inviare
        if notifications_data:
            print(f"📨 Inviate {len(notifications_data)} notifiche a {device.user_id}")
        
        return {
            "notifications": notifications_data,
            "status": "success",
            "count": len(notifications_data)
        }
        
    except Exception as e:
        print(f"❌ Errore nel polling: {e}")
        return {"notifications": [], "status": "error"}

@app.get("/devices")
async def list_devices():
    """Lista tutti i dispositivi registrati (per debug)"""
    device_list = []
    for device in devices.values():
        device_dict = {
            "device_token": device.device_token,
            "user_id": device.user_id,
            "platform": device.platform,
            "app_version": device.app_version,
            "last_seen": device.last_seen,
            "is_online": device.is_online,
            "has_websocket": device.websocket is not None,
            "apns_registered": bool(device.apns_token),
            "apns_environment": device.apns_environment,
            "apns_topic": device.apns_topic,
        }
        device_list.append(device_dict)
    
    return {
        "devices": device_list,
        "count": len(devices)
    }

@app.post("/devices/prune")
async def prune_devices_endpoint(payload: PruneDevicesRequest):
    """Rimuove dispositivi obsoleti o senza token APNs."""
    max_age_seconds = None
    if payload.max_age_days is not None:
        max_age_seconds = max(payload.max_age_days, 0) * 86400

    result = prune_devices(
        max_age_seconds=max_age_seconds,
        remove_without_apns=payload.remove_without_apns,
        dry_run=payload.dry_run,
    )
    result.update({
        "total_devices_after": len(devices),
    })
    return result

@app.post("/initialize")
async def initialize_server():
    """Inizializza le mappature del server"""
    try:
        initialize_mappings()
        return {
            "status": "success",
            "message": "Mappature inizializzate",
            "user_to_device_users": len(user_to_devices),
            "user_to_device_count": sum(len(tokens) for tokens in user_to_devices.values()),
            "device_to_user_count": len(device_to_user)
        }
    except Exception as e:
        print(f"❌ Errore inizializzazione: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/notifications/{user_id}")
async def get_user_notifications(user_id: str):
    """Ottieni tutte le notifiche per un utente (per debug)"""
    user_notifications = notifications.get(user_id, [])
    return {
        "notifications": [asdict(notif) for notif in user_notifications],
        "count": len(user_notifications)
    }

@app.delete("/notifications/{user_id}")
async def clear_user_notifications(user_id: str):
    """Cancella tutte le notifiche per un utente"""
    if user_id in notifications:
        del notifications[user_id]
        return {"status": "success", "message": f"Notifiche cancellate per {user_id}"}
    return {"status": "error", "message": "Utente non trovato"}

@app.get("/health")
async def health_check():
    """Health check del servizio"""
    # 🚀 FIX: Conta WebSocket attivi
    active_websockets = sum(1 for d in devices.values() if d.websocket)
    online_devices = sum(1 for d in devices.values() if d.is_online)
    
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "devices_count": len(devices),
        "active_websockets": active_websockets,
        "online_devices": online_devices,
        "notifications_count": sum(len(notifs) for notifs in notifications.values())
    }

@app.get("/websocket/status/{user_id}")
async def get_websocket_status(user_id: str):
    """Verifica lo stato dei WebSocket per un utente specifico"""
    user_id_str = str(user_id)
    tokens = list(user_to_devices.get(user_id_str, set()))
    
    devices_status = []
    for device_token in tokens:
        device = devices.get(device_token)
        if device:
            devices_status.append({
                "device_token": device_token[:20] + "...",
                "platform": device.platform,
                "has_websocket": device.websocket is not None,
                "is_online": device.is_online,
                "last_seen": device.last_seen,
                "app_version": device.app_version
            })
    
    active_count = sum(1 for d in devices_status if d["has_websocket"])
    
    return {
        "user_id": user_id_str,
        "total_devices": len(devices_status),
        "active_websockets": active_count,
        "devices": devices_status
    }

@app.websocket("/ws/{device_token}")
async def websocket_endpoint(websocket: WebSocket, device_token: str):
    """WebSocket per notifiche real-time"""
    print(f"📡 WebSocket endpoint - Tentativo connessione per device_token: {device_token[:30]}...")
    print(f"📡 WebSocket endpoint - Dispositivi registrati: {len(devices)}")
    
    await websocket.accept()
    print(f"📡 WebSocket endpoint - Connessione accettata")
    
    # 🚀 FIX: Se devices è vuoto, ricarica dal database
    if len(devices) == 0:
        print("⚠️ Dizionario devices vuoto durante connessione WebSocket, ricaricamento dal database...")
        load_devices_from_db()
        initialize_mappings()
        print(f"✅ Ricaricati {len(devices)} dispositivi dal database")
    
    # Trova il dispositivo
    device = devices.get(device_token)
    if not device:
        print(f"❌ WebSocket endpoint - Dispositivo NON trovato per token: {device_token[:30]}...")
        print(f"📋 WebSocket endpoint - Token disponibili: {list(devices.keys())[:5]}...")
        print(f"📋 WebSocket endpoint - Totale dispositivi: {len(devices)}")
        # 🚀 FIX: Prova a cercare il dispositivo nel database se non è in memoria
        try:
            load_devices_from_db()
            initialize_mappings()
            device = devices.get(device_token)
            if device:
                print(f"✅ WebSocket endpoint - Dispositivo trovato nel database dopo ricaricamento")
            else:
                await websocket.close(code=1008, reason="Device not found")
                return
        except Exception as e:
            print(f"❌ WebSocket endpoint - Errore durante ricaricamento database: {e}")
            await websocket.close(code=1008, reason="Device not found")
            return
    
    print(f"✅ WebSocket endpoint - Dispositivo trovato: user_id={device.user_id}, platform={device.platform}")
    
    # 🚀 FIX: Se c'era già un WebSocket attivo, chiudilo prima di sostituirlo
    if device.websocket:
        try:
            print(f"⚠️ WebSocket endpoint - Sostituzione WebSocket esistente per device {device_token[:30]}...")
            await device.websocket.close(code=1000, reason="Replaced by new connection")
        except Exception:
            pass  # Ignora errori se il WebSocket era già chiuso
    
    # OBSERVABILITY B1: Genera ws_conn_id e device_id_hash
    ws_conn_id = str(uuid.uuid4())
    device_id_hash = hashlib.sha256(device_token.encode()).hexdigest()[:16]
    
    # Aggiorna il WebSocket del dispositivo
    device.websocket = websocket
    device.is_online = True
    device.last_seen = time.time()
    device.ws_conn_id = ws_conn_id
    device.device_id_hash = device_id_hash
    
    # Aggiorna le mappature
    user_to_devices.setdefault(device.user_id, set()).add(device.device_token)
    device_to_user[device.device_token] = device.user_id
    
    # OBSERVABILITY B1: Log strutturato JSON con correlation IDs
    print(json.dumps({
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'level': 'INFO',
        'service': 'notify',
        'event_type': 'ws.connected.success',
        'ws_conn_id': ws_conn_id,
        'device_id_hash': device_id_hash,
        'user_id': device.user_id,
        'status': 'success',
    }))
    
    try:
        while True:
            # Mantieni la connessione attiva
            data = await websocket.receive_text()
            message = json.loads(data)
            
            # Aggiorna last_seen ad ogni messaggio
            device.last_seen = time.time()
            
            # Gestisci messaggi dal client
            if message.get("type") == "ping":
                await websocket.send_text(json.dumps({"type": "pong", "timestamp": time.time()}))
            elif message.get("type") == "call_response":
                # Gestisci risposta chiamata
                call_id = message.get("call_id")
                action = message.get("action")  # "answer", "reject", "end"
                user_id = device.user_id
                
                if action == "answer":
                    await answer_call(call_id, user_id)
                elif action == "reject":
                    await reject_call(call_id, user_id)
                elif action == "end":
                    await end_call(call_id, user_id)
                    
    except WebSocketDisconnect:
        print("")
        print("=" * 80)
        print("📡 SERVER NOTIFY - WEBSOCKET DISCONNESSO")
        print("=" * 80)
        print(f"📡 User ID: {device.user_id}")
        print(f"📡 Device Token: {device_token[:30]}...")
        print(f"📡 Totale WebSocket attivi rimanenti: {sum(1 for d in devices.values() if d.websocket)}")
        print("=" * 80)
        print("")
        device.websocket = None
        device.is_online = False
    except Exception as e:
        print("")
        print("=" * 80)
        print("❌ SERVER NOTIFY - ERRORE WEBSOCKET")
        print("=" * 80)
        print(f"❌ User ID: {device.user_id}")
        print(f"❌ Device Token: {device_token[:30]}...")
        print(f"❌ Errore: {e}")
        print(f"❌ Tipo errore: {type(e).__name__}")
        import traceback
        print(f"❌ Traceback: {traceback.format_exc()}")
        print("=" * 80)
        print("")
        device.websocket = None
        device.is_online = False

@app.get("/calls/active")
async def get_active_calls():
    """Ottieni tutte le chiamate attive"""
    return {
        "active_calls": list(active_calls.values()),
        "count": len(active_calls)
    }

@app.get("/calls/{call_id}")
async def get_call_info(call_id: str):
    """Ottieni informazioni su una chiamata specifica"""
    if call_id not in active_calls:
        raise HTTPException(status_code=404, detail="Chiamata non trovata")
    
    return {
        "call": active_calls[call_id],
        "status": "found"
    }

@app.post("/typing/start")
async def start_typing_indicator(typing_data: dict):
    """Invia notifica typing start via WebSocket"""
    try:
        chat_id = typing_data.get('chat_id')
        sender_id = typing_data.get('sender_id')
        sender_name = typing_data.get('sender_name', '')
        recipient_id = typing_data.get('recipient_id')
        typing_type = typing_data.get('typing_type', 'text')  # 'text' o 'voice'
        
        print(f"📝 FastAPI /typing/start - Ricevuto: chat_id={chat_id}, sender_id={sender_id}, recipient_id={recipient_id}, typing_type={typing_type}")
        
        if not all([chat_id, sender_id, recipient_id]):
            print(f"❌ FastAPI /typing/start - Parametri mancanti: chat_id={chat_id}, sender_id={sender_id}, recipient_id={recipient_id}")
            raise HTTPException(status_code=400, detail="Parametri mancanti")
        
        # Invia notifica typing via WebSocket
        notification_data = {
            "type": "typing_start",
            "chat_id": chat_id,
            "sender_id": sender_id,
            "sender_name": sender_name,
            "typing_type": typing_type,
            "timestamp": time.time()
        }
        
        print(f"📝 FastAPI /typing/start - Invio WebSocket a recipient_id={recipient_id}, payload={notification_data}")
        delivered = await send_websocket_notification(recipient_id, notification_data)
        print(f"📝 FastAPI /typing/start - Risultato invio: delivered={delivered}")
        
        return {
            "status": "typing_started",
            "delivered": delivered,
            "typing_type": typing_type
        }
    except Exception as e:
        print(f"❌ Errore start_typing_indicator: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/typing/stop")
async def stop_typing_indicator(typing_data: dict):
    """Invia notifica typing stop via WebSocket"""
    try:
        chat_id = typing_data.get('chat_id')
        sender_id = typing_data.get('sender_id')
        recipient_id = typing_data.get('recipient_id')
        
        print(f"📝 FastAPI /typing/stop - Ricevuto: chat_id={chat_id}, sender_id={sender_id}, recipient_id={recipient_id}")
        
        if not all([chat_id, sender_id, recipient_id]):
            print(f"❌ FastAPI /typing/stop - Parametri mancanti: chat_id={chat_id}, sender_id={sender_id}, recipient_id={recipient_id}")
            raise HTTPException(status_code=400, detail="Parametri mancanti")
        
        # Invia notifica typing stop via WebSocket
        notification_data = {
            "type": "typing_stop",
            "chat_id": chat_id,
            "sender_id": sender_id,
            "timestamp": time.time()
        }
        
        print(f"📝 FastAPI /typing/stop - Invio WebSocket a recipient_id={recipient_id}, payload={notification_data}")
        delivered = await send_websocket_notification(recipient_id, notification_data)
        print(f"📝 FastAPI /typing/stop - Risultato invio: delivered={delivered}")
        
        return {
            "status": "typing_stopped",
            "delivered": delivered
        }
    except Exception as e:
        print(f"❌ Errore stop_typing_indicator: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/call/group/start")
async def start_group_call(call_data: GroupCallRequest):
    """Inizia una chiamata di gruppo"""
    try:
        call_id = call_data.call_id or generate_call_id()
        
        # Verifica che tutti i membri siano online
        online_members = []
        offline_members = []
        
        for member_id in call_data.group_members:
            device_found = False
            for device in devices.values():
                if device.user_id == member_id and device.is_online:
                    online_members.append(member_id)
                    device_found = True
                    break
            if not device_found:
                offline_members.append(member_id)
        
        if not online_members:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Nessun membro del gruppo è online"
            )
        
        # Crea chiamata di gruppo
        call_info = {
            "call_id": call_id,
            "sender_id": call_data.sender_id,
            "call_type": call_data.call_type,
            "is_group": True,
            "group_members": call_data.group_members,
            "online_members": online_members,
            "offline_members": offline_members,
            "room_name": call_data.room_name,
            "max_participants": call_data.max_participants,
            "status": CallStatus.INCOMING,
            "start_time": time.time(),
            "end_time": None,
            "duration": None,
            "webrtc_session": None,
            "janus_room_id": None,
            "participants_joined": []
        }
        
        active_calls[call_id] = call_info
        
        # Invia notifiche a tutti i membri online
        for member_id in online_members:
            if member_id != call_data.sender_id:  # Non notificare il creatore
                notification = Notification(
                    id=generate_notification_id(),
                    recipient_id=member_id,
                    title=f"Chiamata di gruppo {call_data.call_type}",
                    body=f"{call_data.room_name} - Invitato da {call_data.sender_id}",
                    data={
                        "call_id": call_id,
                        "call_type": call_data.call_type,
                        "is_group": True,
                        "group_members": call_data.group_members,
                        "room_name": call_data.room_name,
                        "sender_id": call_data.sender_id,
                        "timestamp": time.time(),
                        "priority": "high"
                    },
                    sender_id=call_data.sender_id,
                    timestamp=time.time(),
                    notification_type=NotificationType.GROUP_CALL if call_data.call_type == "audio" else NotificationType.GROUP_VIDEO_CALL,
                    call_status=CallStatus.INCOMING,
                    delivered=False
                )
                
                # Aggiungi alla coda notifiche
                if member_id not in notifications:
                    notifications[member_id] = []
                notifications[member_id].append(notification)
                
                # Invia tramite WebSocket
                call_notification = {
                    "type": "group_call",
                    "call_id": call_id,
                    "call_type": call_data.call_type,
                    "room_name": call_data.room_name,
                    "sender_id": call_data.sender_id,
                    "group_members": call_data.group_members,
                    "online_members": online_members,
                    "status": CallStatus.INCOMING.value,
                    "timestamp": time.time(),
                    "priority": "high",
                    "timeout": 60  # Timeout più lungo per chiamate di gruppo
                }
                await send_websocket_notification(member_id, call_notification)
        
        # Programma timeout automatico
        asyncio.create_task(auto_timeout_call(call_id, 60))
        
        print(f"📞 Chiamata di gruppo {call_data.call_type} iniziata: {call_id}")
        print(f"📞 Creatore: {call_data.sender_id}, Membri online: {len(online_members)}")
        if offline_members:
            print(f"📞 Membri offline: {offline_members}")
        
        return CallResponse(
            call_id=call_id,
            status=CallStatus.INCOMING,
            message=f"Chiamata di gruppo inviata a {len(online_members)} membri"
        )
        
    except Exception as e:
        print(f"❌ Errore nell'inizio chiamata di gruppo: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/call/group/join/{call_id}")
async def join_group_call(call_id: str, request_data: CallAnswerRequest):
    """Partecipa a una chiamata di gruppo"""
    try:
        if call_id not in active_calls:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Chiamata di gruppo non trovata"
            )
        
        call_info = active_calls[call_id]
        
        # Verifica che l'utente sia nei membri del gruppo
        if request_data.user_id not in call_info["group_members"]:
            return CallResponse(
                call_id=call_id,
                status=CallStatus.REJECTED,
                message="Non autorizzato a partecipare a questa chiamata"
            )
        
        # Aggiungi ai partecipanti
        if request_data.user_id not in call_info["participants_joined"]:
            call_info["participants_joined"].append(request_data.user_id)
        
        # Se è il primo a partecipare, crea la sessione WebRTC
        if not call_info["webrtc_session"] and len(call_info["participants_joined"]) == 1:
            # Integra con server WebRTC per creare stanza di gruppo
            webrtc_session = await integrate_with_webrtc_server(
                call_id, 
                "create_group_session", 
                {
                    "room_name": call_info["room_name"],
                    "max_participants": call_info["max_participants"],
                    "call_type": call_info["call_type"],
                    "auth_token": request_data.auth_token
                }
            )
            
            if webrtc_session:
                call_info["webrtc_session"] = webrtc_session
                call_info["janus_room_id"] = webrtc_session.get("room_id")
                call_info["status"] = CallStatus.ANSWERED
        
        # Notifica tutti i partecipanti del nuovo membro
        for member_id in call_info["participants_joined"]:
            member_notification = {
                "type": "group_call_member_joined",
                "call_id": call_id,
                "joined_member": request_data.user_id,
                "participants_count": len(call_info["participants_joined"]),
                "webrtc_session": call_info["webrtc_session"],
                "timestamp": time.time()
            }
            await send_websocket_notification(member_id, member_notification)
        
        print(f"📞 {request_data.user_id} si è unito alla chiamata di gruppo {call_id}")
        print(f"📞 Partecipanti totali: {len(call_info['participants_joined'])}")
        
        return CallResponse(
            call_id=call_id,
            status=CallStatus.ANSWERED,
            message="Partecipazione alla chiamata di gruppo confermata"
        )
        
    except Exception as e:
        print(f"❌ Errore nella partecipazione chiamata di gruppo: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/calls/{call_id}")
async def cleanup_call(call_id: str):
    """Pulisci una chiamata terminata"""
    if call_id in active_calls:
        del active_calls[call_id]
        return {"status": "success", "message": f"Chiamata {call_id} pulita"}
    return {"status": "error", "message": "Chiamata non trovata"}

@app.get("/stats")
async def get_stats():
    """Statistiche del servizio"""
    online_devices = sum(1 for device in devices.values() if device.is_online)
    total_notifications = sum(len(notifs) for notifs in notifications.values())
    
    return {
        "devices": {
            "total": len(devices),
            "online": online_devices,
            "offline": len(devices) - online_devices
        },
        "notifications": {
            "total": total_notifications,
            "by_user": {user_id: len(notifs) for user_id, notifs in notifications.items()}
        },
        "calls": {
            "active": len(active_calls),
            "total_today": call_counter
        },
        "platforms": {
            platform: sum(1 for device in devices.values() if device.platform == platform)
            for platform in set(device.platform for device in devices.values())
        }
    }

@app.get("/")
async def root():
    """Endpoint root"""
    return {
        "service": "SecureVOX Notify",
        "version": "1.0.0",
        "status": "running",
        "platforms": ["iOS", "Android", "Web"],
        "features": [
            "Messaggi real-time",
            "Chiamate audio/video",
            "Chiamate di gruppo",
            "Notifiche push",
            "WebSocket real-time"
        ],
        "endpoints": [
            "POST /register - Registra dispositivo",
            "POST /send - Invia notifica",
            "GET /poll/{device_token} - Polling notifiche",
            "WS /ws/{device_token} - WebSocket real-time",
            "POST /call/start - Inizia chiamata 1:1",
            "POST /call/group/start - Inizia chiamata di gruppo",
            "POST /call/answer/{call_id} - Rispondi chiamata",
            "POST /call/group/join/{call_id} - Partecipa a chiamata di gruppo",
            "POST /call/reject/{call_id} - Rifiuta chiamata",
            "POST /call/end/{call_id} - Termina chiamata",
            "GET /devices - Lista dispositivi",
            "GET /calls/active - Chiamate attive",
            "GET /calls/{call_id} - Info chiamata specifica",
            "DELETE /calls/{call_id} - Pulisci chiamata",
            "GET /stats - Statistiche servizio",
            "GET /health - Health check"
        ]
    }

if __name__ == "__main__":
    print("🚀 Avvio SecureVOX Notify...")
    print("🔥 Server in ascolto su http://localhost:8002")
    print("📡 WebSocket disponibile su ws://localhost:8002/ws/{device_token}")
    print("📱 Supporta iOS, Android e Web")
    print("")
    
    # 💾 Bootstrap completo (database, mappature, APNs)
    bootstrap()
    print(f"✅ Bootstrap completato! Dispositivi caricati: {len(devices)}")
    print("")
    
    # Disabilita reload in produzione
    is_production = os.getenv("ENVIRONMENT", "").lower() == "production" or \
                   os.getenv("DJANGO_DEBUG", "").lower() == "false" or \
                   not os.getenv("DEBUG", "0") in ["1", "true", "True"]
    reload_enabled = not is_production
    
    if is_production:
        print("🏭 Modalità PRODUZIONE: reload disabilitato")
    else:
        print("🔧 Modalità SVILUPPO: reload abilitato")
    print("")
    
    uvicorn.run(
        "securevox_notify:app",
        host="0.0.0.0",
        port=8002,
        reload=reload_enabled,
        log_level="info"
    )
