"""
SecureChat - Push Notifications via server proprietario
Sostituisce Firebase con chiamate HTTP al securechat_notify (FastAPI su porta 8002)
"""

import logging
import os
import time
import uuid
import requests
from typing import Optional, Dict, Any

logger = logging.getLogger(__name__)

# URL del notify server (interno Docker)
NOTIFY_BASE_URL = os.getenv(
    "NOTIFY_BASE_URL",
    os.getenv("NOTIFY_SERVER_URL", "http://notify-server:8002")
).rstrip("/")

# Chiave di sicurezza inter-servizi
NOTIFY_SERVICE_KEY = os.getenv("NOTIFY_SERVICE_KEY", "").strip()

# Timeout HTTP verso il notify server
NOTIFY_TIMEOUT = float(os.getenv("NOTIFY_TIMEOUT", "10"))


def _notify_headers() -> Dict[str, str]:
    """Restituisce gli header per le chiamate al notify server."""
    headers = {"Content-Type": "application/json"}
    if NOTIFY_SERVICE_KEY:
        headers["X-Notify-Service-Key"] = NOTIFY_SERVICE_KEY
    return headers


def send_push_notification(
    user_id: int,
    title: str,
    body: str,
    data: Optional[Dict[str, Any]] = None,
    notification_type: str = "message",
    sender_id: Optional[int] = None,
    encrypted: bool = False,
    encrypted_payload: Optional[Dict] = None,
) -> bool:
    """
    Invia una notifica push tramite il server notify proprietario.

    Args:
        user_id: ID utente destinatario
        title: Titolo della notifica
        body: Corpo della notifica
        data: Dati extra (dict)
        notification_type: Tipo notifica (message, call, video_call, system, ...)
        sender_id: ID utente mittente
        encrypted: Se True, usa encrypted_payload
        encrypted_payload: Payload cifrato E2E {ciphertext, iv, mac}

    Returns:
        True se la notifica è stata inviata/accodata, False altrimenti
    """
    if not NOTIFY_BASE_URL:
        logger.error("NOTIFY_BASE_URL non configurato, notifica non inviata")
        return False

    payload = {
        "recipient_id": str(user_id),
        "title": title,
        "body": body,
        "data": data or {},
        "sender_id": str(sender_id) if sender_id else "system",
        "timestamp": str(time.time()),
        "notification_type": notification_type,
    }

    if encrypted and encrypted_payload:
        payload["encrypted"] = True
        payload["encrypted_payload"] = encrypted_payload

    try:
        response = requests.post(
            f"{NOTIFY_BASE_URL}/send",
            json=payload,
            headers=_notify_headers(),
            timeout=NOTIFY_TIMEOUT,
        )

        if response.status_code == 200:
            result = response.json()
            status = result.get("status", "unknown")
            if status in ("success", "partial", "duplicate"):
                logger.info(
                    f"Notifica inviata a user {user_id} | tipo={notification_type} | status={status}"
                )
                return True
            else:
                logger.warning(
                    f"Notify server ha risposto con status={status} per user {user_id}: {result}"
                )
                return False
        else:
            logger.error(
                f"Errore notify server per user {user_id}: HTTP {response.status_code} - {response.text[:200]}"
            )
            return False

    except requests.exceptions.ConnectionError:
        logger.error(
            f"Impossibile connettersi al notify server ({NOTIFY_BASE_URL}) per user {user_id}"
        )
        return False
    except requests.exceptions.Timeout:
        logger.error(
            f"Timeout connessione al notify server per user {user_id} (timeout={NOTIFY_TIMEOUT}s)"
        )
        return False
    except Exception as e:
        logger.exception(f"Errore imprevisto invio notifica a user {user_id}: {e}")
        return False


def send_message_notification(
    recipient_id: int,
    sender_id: int,
    sender_name: str,
    message_preview: str,
    conversation_id: int,
    message_id: Optional[str] = None,
) -> bool:
    """Notifica per nuovo messaggio."""
    data = {
        "type": "message",
        "conversation_id": str(conversation_id),
        "sender_id": str(sender_id),
        "sender_name": sender_name,
    }
    if message_id:
        data["message_id"] = str(message_id)

    return send_push_notification(
        user_id=recipient_id,
        title=sender_name,
        body=message_preview,
        data=data,
        notification_type="message",
        sender_id=sender_id,
    )


def send_call_notification(
    recipient_id: int,
    caller_id: int,
    caller_name: str,
    call_type: str = "audio",
    call_id: Optional[str] = None,
) -> bool:
    """Notifica per chiamata in arrivo (audio o video)."""
    if call_id is None:
        call_id = str(uuid.uuid4())

    notification_type = "video_call" if call_type == "video" else "call"
    title = "Chiamata in arrivo"
    body = f"{'Videochiamata' if call_type == 'video' else 'Chiamata audio'} da {caller_name}"

    data = {
        "type": "call",
        "call_id": call_id,
        "call_type": call_type,
        "caller_id": str(caller_id),
        "caller_name": caller_name,
    }

    return send_push_notification(
        user_id=recipient_id,
        title=title,
        body=body,
        data=data,
        notification_type=notification_type,
        sender_id=caller_id,
    )


def send_call_event_notification(
    recipient_id: int,
    caller_id: int,
    call_id: str,
    event: str,  # accepted, rejected, ended, missed
    call_type: str = "audio",
) -> bool:
    """Notifica per evento chiamata (accettata, rifiutata, terminata, persa)."""
    data = {
        "type": "call_event",
        "call_id": call_id,
        "call_type": call_type,
        "event": event,
        "by_user_id": str(caller_id),
    }

    titles = {
        "accepted": "Chiamata accettata",
        "rejected": "Chiamata rifiutata",
        "ended": "Chiamata terminata",
        "missed": "Chiamata persa",
    }

    return send_push_notification(
        user_id=recipient_id,
        title=titles.get(event, "Evento chiamata"),
        body=titles.get(event, f"Evento: {event}"),
        data={"type": "call_event", "data": data},
        notification_type="call",
        sender_id=caller_id,
    )


def send_system_notification(
    user_id: int,
    title: str,
    body: str,
    data: Optional[Dict] = None,
) -> bool:
    """Notifica di sistema (es. cambio chiavi E2E, aggiornamento, ecc.)."""
    return send_push_notification(
        user_id=user_id,
        title=title,
        body=body,
        data=data or {},
        notification_type="system",
        sender_id=None,
    )


def register_device(
    user_id: int,
    device_token: str,
    platform: str,
    app_version: str,
    apns_token: Optional[str] = None,
    apns_topic: Optional[str] = None,
    apns_environment: Optional[str] = None,
    fcm_token: Optional[str] = None,
    device_id: Optional[str] = None,
) -> bool:
    """
    Registra un dispositivo nel notify server.
    Chiamato dall'endpoint Django POST /api/devices/register/
    """
    payload = {
        "device_token": device_token,
        "user_id": str(user_id),
        "platform": platform,
        "app_version": app_version,
    }
    if apns_token:
        payload["apns_token"] = apns_token
    if apns_topic:
        payload["apns_topic"] = apns_topic
    if apns_environment:
        payload["apns_environment"] = apns_environment
    if fcm_token:
        payload["fcm_token"] = fcm_token
    if device_id:
        payload["device_id"] = device_id

    try:
        response = requests.post(
            f"{NOTIFY_BASE_URL}/register",
            json=payload,
            headers=_notify_headers(),
            timeout=NOTIFY_TIMEOUT,
        )
        if response.status_code == 200:
            logger.info(f"Dispositivo registrato per user {user_id} | platform={platform}")
            return True
        else:
            logger.error(
                f"Errore registrazione dispositivo user {user_id}: HTTP {response.status_code} - {response.text[:200]}"
            )
            return False
    except Exception as e:
        logger.exception(f"Errore registrazione dispositivo user {user_id}: {e}")
        return False


def unregister_device(
    user_id: int,
    device_token: Optional[str] = None,
    apns_token: Optional[str] = None,
    fcm_token: Optional[str] = None,
) -> bool:
    """
    Deregistra un dispositivo dal notify server.
    Chiamato al logout o alla disinstallazione.
    """
    payload: Dict[str, Any] = {"user_id": str(user_id)}
    if device_token:
        payload["device_token"] = device_token
    if apns_token:
        payload["apns_token"] = apns_token
    if fcm_token:
        payload["fcm_token"] = fcm_token

    try:
        response = requests.post(
            f"{NOTIFY_BASE_URL}/unregister",
            json=payload,
            headers=_notify_headers(),
            timeout=NOTIFY_TIMEOUT,
        )
        if response.status_code == 200:
            logger.info(f"Dispositivo deregistrato per user {user_id}")
            return True
        else:
            logger.warning(
                f"Errore deregistrazione dispositivo user {user_id}: HTTP {response.status_code}"
            )
            return False
    except Exception as e:
        logger.exception(f"Errore deregistrazione dispositivo user {user_id}: {e}")
        return False
