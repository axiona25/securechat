import logging
from datetime import timedelta
from django.utils import timezone
from django.core.mail import send_mail
from django.conf import settings
from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.parsers import MultiPartParser, FormParser
from rest_framework_simplejwt.tokens import RefreshToken
from PIL import Image
from io import BytesIO
from django.core.files.uploadedfile import InMemoryUploadedFile
import sys

from django.db.models import Q
from .models import User, EmailVerificationToken, PasswordResetToken
from .serializers import (
    RegisterSerializer, VerifyEmailSerializer, LoginSerializer,
    ForgotPasswordSerializer, ResetPasswordSerializer,
    ChangePasswordSerializer, UserProfileSerializer
)

try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:
    pass

logger = logging.getLogger(__name__)


class RegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = RegisterSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = serializer.save()

        # Get the verification code
        token = user.verification_tokens.first()

        # Send verification email (console in dev)
        try:
            send_mail(
                subject='SecureChat - Verifica il tuo account',
                message=f'Il tuo codice di verifica è: {token.code}\n\nIl codice scade tra 24 ore.',
                from_email=settings.DEFAULT_FROM_EMAIL,
                recipient_list=[user.email],
                fail_silently=False,
            )
        except Exception as e:
            logger.error(f'Failed to send verification email: {e}')

        return Response({
            'message': 'Registrazione completata. Controlla la tua email per il codice di verifica.',
            'email': user.email,
        }, status=status.HTTP_201_CREATED)


class VerifyEmailView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = VerifyEmailSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        email = serializer.validated_data['email'].lower()
        code = serializer.validated_data['code']

        try:
            user = User.objects.get(email=email)
        except User.DoesNotExist:
            return Response({'error': 'Utente non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        if user.is_verified:
            return Response({'message': 'Account già verificato.'}, status=status.HTTP_200_OK)

        token = EmailVerificationToken.objects.filter(
            user=user, code=code, is_used=False
        ).first()

        if not token:
            return Response({'error': 'Codice non valido.'}, status=status.HTTP_400_BAD_REQUEST)

        if token.is_expired():
            return Response({'error': 'Codice scaduto. Richiedi un nuovo codice.'}, status=status.HTTP_400_BAD_REQUEST)

        token.is_used = True
        token.save()
        user.is_verified = True
        user.save()

        return Response({'message': 'Email verificata con successo! Ora puoi accedere.'}, status=status.HTTP_200_OK)


class ResendVerificationView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        email = request.data.get('email', '').lower()
        try:
            user = User.objects.get(email=email)
        except User.DoesNotExist:
            return Response({'message': 'Se l\'email esiste, riceverai un nuovo codice.'}, status=status.HTTP_200_OK)

        if user.is_verified:
            return Response({'message': 'Account già verificato.'}, status=status.HTTP_200_OK)

        import random
        code = str(random.randint(100000, 999999))
        EmailVerificationToken.objects.create(
            user=user, code=code, expires_at=timezone.now() + timedelta(hours=24)
        )
        try:
            send_mail(
                subject='SecureChat - Nuovo codice di verifica',
                message=f'Il tuo nuovo codice di verifica è: {code}',
                from_email=settings.DEFAULT_FROM_EMAIL,
                recipient_list=[user.email],
                fail_silently=False,
            )
        except Exception as e:
            logger.error(f'Failed to send verification email: {e}')

        return Response({'message': 'Se l\'email esiste, riceverai un nuovo codice.'}, status=status.HTTP_200_OK)


class LoginView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = LoginSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        user = serializer.validated_data['user']

        # Generate JWT tokens
        refresh = RefreshToken.for_user(user)
        # Add custom claims
        refresh['email'] = user.email
        refresh['first_name'] = user.first_name
        refresh['last_name'] = user.last_name
        refresh['language'] = user.language

        # Update online status
        user.is_online = True
        user.last_seen = timezone.now()
        user.save(update_fields=['is_online', 'last_seen'])

        profile_serializer = UserProfileSerializer(user, context={'request': request})

        return Response({
            'access': str(refresh.access_token),
            'refresh': str(refresh),
            'user': profile_serializer.data,
        }, status=status.HTTP_200_OK)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def heartbeat(request):
    """Endpoint leggero per segnalare che l'utente è online (es. app in foreground)."""
    request.user.is_online = True
    request.user.last_seen = timezone.now()
    request.user.save(update_fields=['is_online', 'last_seen'])
    return Response({'status': 'ok'}, status=status.HTTP_200_OK)


class LogoutView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        try:
            refresh_token = request.data.get('refresh')
            if refresh_token:
                token = RefreshToken(refresh_token)
                token.blacklist()

            request.user.is_online = False
            request.user.last_seen = timezone.now()
            request.user.save(update_fields=['is_online', 'last_seen'])

            return Response({'message': 'Logout effettuato.'}, status=status.HTTP_200_OK)
        except Exception as e:
            return Response({'error': 'Token non valido.'}, status=status.HTTP_400_BAD_REQUEST)


class ForgotPasswordView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = ForgotPasswordSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        email = serializer.validated_data['email'].lower()

        try:
            user = User.objects.get(email=email)
            # Invalidate old tokens
            PasswordResetToken.objects.filter(user=user, is_used=False).update(is_used=True)
            # Create new token
            reset_token = PasswordResetToken.objects.create(
                user=user,
                expires_at=timezone.now() + timedelta(minutes=15)
            )
            try:
                send_mail(
                    subject='SecureChat - Reset Password',
                    message=f'Il tuo token di reset è: {reset_token.token}\n\nScade tra 15 minuti.',
                    from_email=settings.DEFAULT_FROM_EMAIL,
                    recipient_list=[user.email],
                    fail_silently=False,
                )
            except Exception as e:
                logger.error(f'Failed to send reset email: {e}')
        except User.DoesNotExist:
            pass  # Don't reveal if email exists

        return Response({
            'message': 'Se l\'email è registrata, riceverai un link per il reset della password.'
        }, status=status.HTTP_200_OK)


class ResetPasswordView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = ResetPasswordSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        token_uuid = serializer.validated_data['token']
        new_password = serializer.validated_data['new_password']

        try:
            reset_token = PasswordResetToken.objects.get(token=token_uuid, is_used=False)
        except PasswordResetToken.DoesNotExist:
            return Response({'error': 'Token non valido.'}, status=status.HTTP_400_BAD_REQUEST)

        if reset_token.is_expired():
            return Response({'error': 'Token scaduto. Richiedi un nuovo reset.'}, status=status.HTTP_400_BAD_REQUEST)

        user = reset_token.user
        user.set_password(new_password)
        user.save()

        reset_token.is_used = True
        reset_token.save()

        return Response({'message': 'Password aggiornata con successo!'}, status=status.HTTP_200_OK)


class UserLookupView(APIView):
    """GET ?email=... — returns {id, email} for starting a chat. Auth required."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        email = (request.query_params.get('email') or '').strip().lower()
        if not email:
            return Response({'error': 'Email richiesta.'}, status=status.HTTP_400_BAD_REQUEST)
        if email == request.user.email:
            return Response({'error': 'Non puoi avviare una chat con te stesso.'}, status=status.HTTP_400_BAD_REQUEST)
        try:
            user = User.objects.get(email=email, is_active=True)
        except User.DoesNotExist:
            return Response({'error': 'Utente non trovato.'}, status=status.HTTP_404_NOT_FOUND)
        return Response({'id': user.id, 'email': user.email})


class ProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        serializer = UserProfileSerializer(request.user, context={'request': request})
        return Response(serializer.data)

    def put(self, request):
        serializer = UserProfileSerializer(
            request.user, data=request.data, partial=True, context={'request': request}
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)

    def patch(self, request):
        return self.put(request)


class AvatarUploadView(APIView):
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request):
        avatar_file = request.FILES.get('avatar')
        if not avatar_file:
            return Response({'error': 'Nessun file caricato.'}, status=status.HTTP_400_BAD_REQUEST)

        # Validate file type
        allowed_types = ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/octet-stream']
        if avatar_file.content_type not in allowed_types:
            return Response({'error': 'Formato non supportato. Usa JPG, PNG o WebP.'}, status=status.HTTP_400_BAD_REQUEST)

        # Validate file size (max 5MB)
        if avatar_file.size > 5 * 1024 * 1024:
            return Response({'error': 'File troppo grande. Massimo 5MB.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            # Resize image
            img = Image.open(avatar_file)
            img = img.convert('RGB')
            img.thumbnail((500, 500), Image.LANCZOS)

            # Save to buffer
            buffer = BytesIO()
            img.save(buffer, format='JPEG', quality=85)
            buffer.seek(0)

            # Create InMemoryUploadedFile
            file_name = f'avatar_{request.user.id}.jpg'
            resized = InMemoryUploadedFile(
                buffer, 'avatar', file_name, 'image/jpeg', sys.getsizeof(buffer), None
            )

            # Delete old avatar if exists
            if request.user.avatar:
                request.user.avatar.delete(save=False)

            request.user.avatar = resized
            request.user.save(update_fields=['avatar'])

            serializer = UserProfileSerializer(request.user, context={'request': request})
            return Response({
                'message': 'Avatar aggiornato.',
                'avatar_url': request.build_absolute_uri(request.user.avatar.url) if request.user.avatar else None,
                'user': serializer.data,
            }, status=status.HTTP_200_OK)

        except Exception as e:
            logger.error(f'Avatar upload error: {e}')
            return Response({'error': 'Errore durante il caricamento.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class ChangePasswordView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = ChangePasswordSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        if not request.user.check_password(serializer.validated_data['old_password']):
            return Response({'error': 'Password attuale non corretta.'}, status=status.HTTP_400_BAD_REQUEST)

        request.user.set_password(serializer.validated_data['new_password'])
        request.user.save()

        return Response({'message': 'Password cambiata con successo!'}, status=status.HTTP_200_OK)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def search_users(request):
    """GET /api/auth/users/search/?q=<query> — list all or search by email, first_name, last_name, username. Excludes current user and staff."""
    query = request.GET.get('q', '').strip()

    if len(query) < 2:
        users = (
            User.objects.filter(is_active=True)
            .exclude(id=request.user.id)
            .exclude(is_staff=True)
            .order_by('first_name', 'last_name')[:100]
        )
    else:
        users = (
            User.objects.filter(
                Q(email__icontains=query)
                | Q(first_name__icontains=query)
                | Q(last_name__icontains=query)
                | Q(username__icontains=query),
                is_active=True,
            )
            .exclude(id=request.user.id)
            .exclude(is_staff=True)
            .order_by('first_name', 'last_name')[:20]
        )

    return Response([
        {
            'id': u.id,
            'email': u.email,
            'first_name': u.first_name or '',
            'last_name': u.last_name or '',
            'username': u.username or '',
            'avatar_url': request.build_absolute_uri(u.avatar.url) if (getattr(u, 'avatar', None) and u.avatar) else None,
            'is_online': getattr(u, 'is_online', False),
            'last_seen': u.last_seen.isoformat() if getattr(u, 'last_seen', None) else None,
        }
        for u in users
    ])
