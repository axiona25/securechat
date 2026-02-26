import base64
import logging
from datetime import timedelta
from django.db import transaction
from django.utils import timezone
from django.conf import settings
from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework.throttling import UserRateThrottle
from .models import UserKeyBundle, OneTimePreKey, KeyBundleFetchLog, SecurityAlert
from .scp_keys import (
    verify_signed_prekey,
    verify_signed_prekey_versioned,
    generate_safety_number,
    generate_safety_qr_data,
)

logger = logging.getLogger(__name__)


class KeyUploadThrottle(UserRateThrottle):
    """Limit key uploads to prevent abuse"""
    rate = '10/hour'


class KeyFetchThrottle(UserRateThrottle):
    """Limit key fetches to detect enumeration attacks"""
    rate = '60/hour'


class UploadKeyBundleView(APIView):
    permission_classes = [IsAuthenticated]
    throttle_classes = [KeyUploadThrottle]

    def post(self, request):
        """
        Upload identity key, signed prekey, and one-time prekeys.
        Called once at registration and when prekeys need replenishing.
        Supports crypto_version=1 (X448/Ed448) and crypto_version=2 (X25519/Ed25519).
        Request body accepts: identity_key_public or identity_key, identity_dh_key_public or identity_dh_key,
        signed_prekey_public or signed_prekey, signed_prekey_signature, signed_prekey_timestamp (v2).
        """
        try:
            crypto_version = int(request.data.get('crypto_version', 2))
            logger.warning(
                f"[KEY UPLOAD] data keys: {list(request.data.keys())}, identity_key_public: {repr(request.data.get('identity_key_public'))[:60]}"
            )
            if crypto_version not in (1, 2):
                return Response({'error': 'crypto_version must be 1 or 2.'}, status=status.HTTP_400_BAD_REQUEST)

            # Accept both naming conventions (identity_key_public / identity_key, etc.)
            identity_key = base64.b64decode(
                request.data.get('identity_key_public') or request.data['identity_key']
            )
            identity_dh_key = base64.b64decode(
                request.data.get('identity_dh_key_public') or request.data['identity_dh_key']
            )
            signed_prekey = base64.b64decode(
                request.data.get('signed_prekey_public') or request.data['signed_prekey']
            )
            signed_prekey_signature = base64.b64decode(request.data['signed_prekey_signature'])
            signed_prekey_id = request.data.get('signed_prekey_id', 0)
            signed_prekey_timestamp = request.data.get('signed_prekey_timestamp')
            one_time_prekeys = request.data.get('one_time_prekeys', [])

            # Validate key sizes by crypto_version
            if crypto_version == 2:
                if len(identity_key) != 32:
                    return Response({'error': 'Identity key must be 32 bytes (Ed25519).'}, status=status.HTTP_400_BAD_REQUEST)
                if len(identity_dh_key) != 32:
                    return Response({'error': 'Identity DH key must be 32 bytes (X25519).'}, status=status.HTTP_400_BAD_REQUEST)
                if len(signed_prekey) != 32:
                    return Response({'error': 'Signed prekey must be 32 bytes (X25519).'}, status=status.HTTP_400_BAD_REQUEST)
                expected_otpk_len = 32
            else:
                if len(identity_key) != 57:
                    return Response({'error': 'Identity key must be 57 bytes (Ed448).'}, status=status.HTTP_400_BAD_REQUEST)
                if len(identity_dh_key) != 56:
                    return Response({'error': 'Identity DH key must be 56 bytes (X448).'}, status=status.HTTP_400_BAD_REQUEST)
                if len(signed_prekey) != 56:
                    return Response({'error': 'Signed prekey must be 56 bytes (X448).'}, status=status.HTTP_400_BAD_REQUEST)
                expected_otpk_len = 56

            # Verify the signed prekey (version-aware)
            if crypto_version == 2:
                if signed_prekey_timestamp is None:
                    return Response({'error': 'signed_prekey_timestamp required for crypto_version=2.'}, status=status.HTTP_400_BAD_REQUEST)
                is_valid = verify_signed_prekey_versioned(
                    crypto_version=crypto_version,
                    identity_public_key_bytes=identity_key,
                    signed_prekey_public_bytes=signed_prekey,
                    signature=signed_prekey_signature,
                    timestamp=int(signed_prekey_timestamp),
                )
            else:
                is_valid = verify_signed_prekey_versioned(
                    crypto_version=crypto_version,
                    identity_public_key_bytes=identity_key,
                    signed_prekey_public_bytes=signed_prekey,
                    full_signature=signed_prekey_signature,
                )
            if not is_valid:
                logger.warning(f'Invalid signed prekey signature from {request.user.email}')
                return Response({'error': 'Firma della signed prekey non valida.'}, status=status.HTTP_400_BAD_REQUEST)

            # Check if identity key changed (potential security event)
            existing_bundle = UserKeyBundle.objects.filter(user=request.user).first()
            if existing_bundle and bytes(existing_bundle.identity_key_public) != identity_key:
                SecurityAlert.objects.create(
                    user=request.user,
                    alert_type='identity_change',
                    severity='high',
                    message=f'Identity key changed for {request.user.email}. '
                            f'This could indicate device change or compromise.',
                    metadata={
                        'old_key_prefix': bytes(existing_bundle.identity_key_public)[:16].hex(),
                        'new_key_prefix': identity_key[:16].hex(),
                        'ip': self._get_client_ip(request),
                    }
                )
                logger.warning(f'SECURITY: Identity key changed for {request.user.email}')

            # signed_prekey_created_at: from timestamp if v2, else now
            if crypto_version == 2 and signed_prekey_timestamp is not None:
                from datetime import datetime
                created_at = timezone.make_aware(datetime.utcfromtimestamp(int(signed_prekey_timestamp)))
            else:
                created_at = timezone.now()

            # Save or update key bundle
            bundle, created = UserKeyBundle.objects.update_or_create(
                user=request.user,
                defaults={
                    'crypto_version': crypto_version,
                    'identity_key_public': identity_key,
                    'identity_dh_public': identity_dh_key,
                    'signed_prekey_public': signed_prekey,
                    'signed_prekey_signature': signed_prekey_signature,
                    'signed_prekey_id': signed_prekey_id,
                    'signed_prekey_created_at': created_at,
                }
            )

            # Save one-time prekeys (support both list of {key_id, public_key} and list of b64 strings)
            created_count = 0
            for i, otpk in enumerate(one_time_prekeys):
                if isinstance(otpk, dict):
                    key_id = otpk.get('key_id', i)
                    pub_b64 = otpk.get('public_key')
                else:
                    key_id = i
                    pub_b64 = otpk
                if not pub_b64:
                    continue
                public_key = base64.b64decode(pub_b64)
                if len(public_key) != expected_otpk_len:
                    continue
                _, was_created = OneTimePreKey.objects.update_or_create(
                    user=request.user, key_id=key_id,
                    defaults={'public_key': public_key, 'is_used': False}
                )
                if was_created:
                    created_count += 1

            # Update user's public key reference if the model has it
            if hasattr(request.user, 'public_key'):
                request.user.public_key = base64.b64encode(identity_key).decode()
                request.user.save(update_fields=['public_key'])

            available = OneTimePreKey.objects.filter(user=request.user, is_used=False).count()

            logger.info(f'Key bundle uploaded by {request.user.email} (crypto_version={crypto_version}): '
                       f'{created_count} new prekeys, {available} total available')

            return Response({
                'message': 'Key bundle caricato con successo.',
                'prekeys_created': created_count,
                'prekeys_available': available,
                'signed_prekey_id': signed_prekey_id,
                'crypto_version': crypto_version,
            }, status=status.HTTP_201_CREATED)

        except KeyError as e:
            return Response({'error': f'Campo mancante: {e}'}, status=status.HTTP_400_BAD_REQUEST)
        except Exception as e:
            logger.error(f'Key bundle upload error for {request.user.email}: {e}')
            return Response({'error': 'Errore nel caricamento delle chiavi.'}, status=status.HTTP_400_BAD_REQUEST)

    def _get_client_ip(self, request):
        x_forwarded = request.META.get('HTTP_X_FORWARDED_FOR')
        return x_forwarded.split(',')[0].strip() if x_forwarded else request.META.get('REMOTE_ADDR')


class GetKeyBundleView(APIView):
    permission_classes = [IsAuthenticated]
    throttle_classes = [KeyFetchThrottle]

    def get(self, request, user_id):
        """
        Get another user's key bundle to initiate an encrypted session.
        Consumes one one-time prekey (marked as used).
        
        Rate limited and logged to detect enumeration/abuse attacks.
        """
        # Don't allow fetching own keys
        if user_id == request.user.id:
            return Response({'error': 'Non puoi richiedere le tue chiavi.'}, 
                          status=status.HTTP_400_BAD_REQUEST)

        try:
            bundle = UserKeyBundle.objects.get(user_id=user_id)
        except UserKeyBundle.DoesNotExist:
            return Response({'error': 'L\'utente non ha ancora configurato la cifratura.'}, 
                          status=status.HTTP_404_NOT_FOUND)

        # Log the fetch for security auditing
        KeyBundleFetchLog.objects.create(
            requester=request.user,
            target_user_id=user_id,
            ip_address=self._get_client_ip(request),
            user_agent=request.META.get('HTTP_USER_AGENT', '')[:500],
        )

        # Check for excessive fetches (possible attack)
        recent_fetches = KeyBundleFetchLog.objects.filter(
            requester=request.user,
            fetched_at__gte=timezone.now() - timedelta(hours=1)
        ).count()

        if recent_fetches > 50:
            SecurityAlert.objects.create(
                user=request.user,
                alert_type='excessive_fetch',
                severity='high',
                message=f'{request.user.email} fetched {recent_fetches} key bundles in 1 hour.',
                metadata={'count': recent_fetches, 'ip': self._get_client_ip(request)}
            )
            logger.warning(f'SECURITY: Excessive key fetches by {request.user.email}: {recent_fetches}/hour')

        # Get one unused one-time prekey (atomic to prevent race conditions)
        with transaction.atomic():
            otpk = OneTimePreKey.objects.filter(
                user_id=user_id, is_used=False
            ).select_for_update().first()
            if otpk:
                otpk.is_used = True
                otpk.used_by = request.user
                otpk.used_at = timezone.now()
                otpk.save()

        response_data = {
            'user_id': user_id,
            'crypto_version': getattr(bundle, 'crypto_version', 1),
            'identity_key': base64.b64encode(bytes(bundle.identity_key_public)).decode(),
            'identity_dh_key': base64.b64encode(bytes(bundle.identity_dh_public)).decode() if bundle.identity_dh_public else None,
            'signed_prekey': base64.b64encode(bytes(bundle.signed_prekey_public)).decode(),
            'signed_prekey_signature': base64.b64encode(bytes(bundle.signed_prekey_signature)).decode(),
            'signed_prekey_id': bundle.signed_prekey_id,
            'signed_prekey_timestamp': int(bundle.signed_prekey_created_at.timestamp()) if bundle.signed_prekey_created_at else None,
            'one_time_prekey': None,
            'one_time_prekey_id': None,
        }

        if otpk:
            response_data['one_time_prekey'] = base64.b64encode(bytes(otpk.public_key)).decode()
            response_data['one_time_prekey_id'] = otpk.key_id

        # Check remaining prekeys
        remaining = OneTimePreKey.objects.filter(user_id=user_id, is_used=False).count()
        response_data['prekeys_remaining'] = remaining

        if remaining == 0:
            SecurityAlert.objects.create(
                user_id=user_id,
                alert_type='prekey_exhaustion',
                severity='medium',
                message=f'All one-time prekeys exhausted for user {user_id}.',
            )
        elif remaining < 20:
            response_data['warning'] = 'Prekeys in esaurimento.'

        # Warn if signed prekey is stale
        if bundle.is_signed_prekey_stale():
            response_data['signed_prekey_stale'] = True

        return Response(response_data)

    def _get_client_ip(self, request):
        x_forwarded = request.META.get('HTTP_X_FORWARDED_FOR')
        return x_forwarded.split(',')[0].strip() if x_forwarded else request.META.get('REMOTE_ADDR')


class ReplenishPreKeysView(APIView):
    permission_classes = [IsAuthenticated]
    throttle_classes = [KeyUploadThrottle]

    def post(self, request):
        """Upload additional one-time prekeys when pool is low."""
        prekeys = request.data.get('one_time_prekeys', [])
        if not prekeys:
            return Response({'error': 'Nessuna prekey fornita.'}, status=status.HTTP_400_BAD_REQUEST)
        
        if len(prekeys) > 200:
            return Response({'error': 'Massimo 200 prekeys per richiesta.'}, 
                          status=status.HTTP_400_BAD_REQUEST)

        # Accept both X448 (56 bytes) and X25519 (32 bytes) prekeys
        count = 0
        for otpk in prekeys:
            key_id = otpk.get('key_id')
            pub_key_b64 = otpk.get('public_key')
            if key_id is None or not pub_key_b64:
                continue
            public_key = base64.b64decode(pub_key_b64)
            if len(public_key) not in (32, 56):
                continue
            _, created = OneTimePreKey.objects.update_or_create(
                user=request.user, key_id=key_id,
                defaults={'public_key': public_key, 'is_used': False}
            )
            if created:
                count += 1

        remaining = OneTimePreKey.objects.filter(user=request.user, is_used=False).count()
        
        logger.info(f'Prekeys replenished by {request.user.email}: +{count}, total={remaining}')
        
        return Response({
            'message': f'{count} nuove prekeys aggiunte.',
            'total_available': remaining
        })


class RotateSignedPreKeyView(APIView):
    permission_classes = [IsAuthenticated]
    throttle_classes = [KeyUploadThrottle]

    def post(self, request):
        """
        Rotate the signed prekey (recommended every 7 days).
        Old sessions continue working; new sessions use the new prekey.
        """
        try:
            signed_prekey = base64.b64decode(request.data['signed_prekey'])
            signed_prekey_signature = base64.b64decode(request.data['signed_prekey_signature'])
            signed_prekey_id = request.data['signed_prekey_id']

            if len(signed_prekey) != 56:
                return Response({'error': 'Invalid signed prekey size.'}, 
                              status=status.HTTP_400_BAD_REQUEST)

            bundle = UserKeyBundle.objects.filter(user=request.user).first()
            if not bundle:
                return Response({'error': 'Upload key bundle first.'}, 
                              status=status.HTTP_400_BAD_REQUEST)

            # Verify signature with existing identity key
            verify_signed_prekey(
                bytes(bundle.identity_key_public), signed_prekey, signed_prekey_signature
            )

            bundle.signed_prekey_public = signed_prekey
            bundle.signed_prekey_signature = signed_prekey_signature
            bundle.signed_prekey_id = signed_prekey_id
            bundle.signed_prekey_created_at = timezone.now()
            bundle.save()

            logger.info(f'Signed prekey rotated for {request.user.email}, id={signed_prekey_id}')

            return Response({
                'message': 'Signed prekey aggiornata.',
                'signed_prekey_id': signed_prekey_id,
            })

        except Exception as e:
            return Response({'error': f'Errore: {str(e)}'}, status=status.HTTP_400_BAD_REQUEST)


class SafetyNumberView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, user_id):
        """
        Generate safety number between current user and another user.
        Both users computing this will get the same number.
        Used for in-person verification (compare numbers or scan QR).
        """
        if user_id == request.user.id:
            return Response({'error': 'Non puoi generare un safety number con te stesso.'}, 
                          status=status.HTTP_400_BAD_REQUEST)

        try:
            my_bundle = UserKeyBundle.objects.get(user=request.user)
            their_bundle = UserKeyBundle.objects.get(user_id=user_id)
        except UserKeyBundle.DoesNotExist:
            return Response({'error': 'Chiavi non disponibili per uno dei due utenti.'}, 
                          status=status.HTTP_404_NOT_FOUND)

        my_ik = bytes(my_bundle.identity_key_public)
        their_ik = bytes(their_bundle.identity_key_public)

        formatted, raw = generate_safety_number(my_ik, their_ik)
        qr_data = generate_safety_qr_data(my_ik, request.user.id, their_ik, user_id)

        return Response({
            'safety_number': formatted,
            'safety_number_raw': raw,
            'qr_data': qr_data,
        })


class PreKeyCountView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """Check prekey availability and signed prekey freshness."""
        count = OneTimePreKey.objects.filter(user=request.user, is_used=False).count()
        
        bundle = UserKeyBundle.objects.filter(user=request.user).first()
        signed_prekey_stale = bundle.is_signed_prekey_stale() if bundle else True
        
        return Response({
            'available_prekeys': count,
            'needs_replenish': count < 20,
            'signed_prekey_stale': signed_prekey_stale,
            'has_key_bundle': bundle is not None,
        })


class SecurityAlertsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """Get unresolved security alerts for current user."""
        alerts = SecurityAlert.objects.filter(
            user=request.user, is_resolved=False
        ).values('id', 'alert_type', 'severity', 'message', 'created_at')[:20]
        
        return Response({'alerts': list(alerts)})

    def post(self, request):
        """Mark a security alert as resolved."""
        alert_id = request.data.get('alert_id')
        try:
            alert = SecurityAlert.objects.get(id=alert_id, user=request.user)
            alert.is_resolved = True
            alert.resolved_at = timezone.now()
            alert.save()
            return Response({'message': 'Alert risolto.'})
        except SecurityAlert.DoesNotExist:
            return Response({'error': 'Alert non trovato.'}, status=status.HTTP_404_NOT_FOUND)
