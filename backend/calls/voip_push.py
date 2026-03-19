
import json
import logging
import os
import tempfile

logger = logging.getLogger(__name__)

VOIP_TOPIC = "com.axphone.app.voip"
CERT_PATH = os.environ.get("VOIP_CERT_PATH", "/app/config/voip_pushkit.p12")
CERT_PASSWORD = os.environ.get("VOIP_CERT_PASSWORD", "")
APNS_PRODUCTION = "https://api.push.apple.com"
APNS_SANDBOX = "https://api.sandbox.push.apple.com"


def send_voip_push(user, call_data):
    voip_token = getattr(user, "voip_token", None)
    if not voip_token or not voip_token.strip():
        logger.debug("User %s has no voip_token, skip VoIP push", user.id)
        return False

    use_sandbox = os.environ.get("APNS_USE_SANDBOX", "false").lower() in ("true", "1", "sandbox", "true")
    # VoIP cert is always sandbox in development
    voip_env = os.environ.get("VOIP_USE_SANDBOX", "true").lower()
    use_sandbox = voip_env not in ("false", "0", "production")

    base_url = APNS_SANDBOX if use_sandbox else APNS_PRODUCTION
    token = voip_token.strip().replace(" ", "").replace("<", "").replace(">", "")
    url = f"{base_url}/3/device/{token}"

    try:
        from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption
        from cryptography.hazmat.primitives.serialization.pkcs12 import load_key_and_certificates
        import httpx

        with open(CERT_PATH, "rb") as f:
            p12_data = f.read()
        password = CERT_PASSWORD.encode("utf-8") if CERT_PASSWORD else b""
        key, cert, _ = load_key_and_certificates(p12_data, password)

        cert_pem = cert.public_bytes(Encoding.PEM)
        key_pem = key.private_bytes(Encoding.PEM, PrivateFormat.TraditionalOpenSSL, NoEncryption())

        cert_file = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
        key_file = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
        cert_file.write(cert_pem); cert_file.close()
        key_file.write(key_pem); key_file.close()

        caller_name = call_data.get("caller_display_name", "") or ""
        payload = {
            "aps": {},
            "handle": caller_name,
            "callerName": caller_name,
            "callId": str(call_data.get("call_id", "")),
            "callType": call_data.get("call_type", "audio"),
            "callerUserId": str(call_data.get("caller_user_id", "")),
            "conversationId": str(call_data.get("conversation_id", "")),
        }

        with httpx.Client(cert=(cert_file.name, key_file.name), http2=True) as client:
            response = client.post(
                url,
                headers={"apns-topic": VOIP_TOPIC, "apns-push-type": "voip", "apns-priority": "10", "content-type": "application/json"},
                content=json.dumps(payload),
                timeout=10,
            )
            # Fallback: if production fails with BadDeviceToken, try sandbox (and vice versa)
            if response.status_code == 400 and "BadDeviceToken" in response.text:
                fallback_base = APNS_SANDBOX if not use_sandbox else APNS_PRODUCTION
                fallback_url = f"{fallback_base}/3/device/{token}"
                logger.info("VoIP push user=%s call=%s primary failed (BadDeviceToken), trying fallback (%s)",
                            user.id, call_data.get("call_id"), "sandbox" if not use_sandbox else "production")
                response = client.post(
                    fallback_url,
                    headers={"apns-topic": VOIP_TOPIC, "apns-push-type": "voip", "apns-priority": "10", "content-type": "application/json"},
                    content=json.dumps(payload),
                    timeout=10,
                )
        logger.info("VoIP push user=%s call=%s status=%s body=%s", user.id, call_data.get("call_id"), response.status_code, response.text)
        return response.status_code == 200
    except Exception as e:
        logger.exception("VoIP push failed for user %s: %s", user.id, e)
        return False
    finally:
        try:
            if "cert_file" in dir() and os.path.exists(cert_file.name): os.unlink(cert_file.name)
            if "key_file" in dir() and os.path.exists(key_file.name): os.unlink(key_file.name)
        except: pass
