import random
from datetime import timedelta
from django.utils import timezone
from django.contrib.auth import authenticate
from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer
from .models import User, EmailVerificationToken, PasswordResetToken


class CustomTokenObtainPairSerializer(TokenObtainPairSerializer):
    @classmethod
    def get_token(cls, user):
        token = super().get_token(user)
        token['email'] = user.email
        token['first_name'] = user.first_name
        token['last_name'] = user.last_name
        token['language'] = user.language
        return token


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, min_length=8, validators=[validate_password])
    password_confirm = serializers.CharField(write_only=True)

    class Meta:
        model = User
        fields = [
            'email', 'username', 'password', 'password_confirm',
            'first_name', 'last_name', 'phone_number', 'country', 'language'
        ]

    def validate_email(self, value):
        if User.objects.filter(email=value).exists():
            raise serializers.ValidationError('Un account con questa email esiste già.')
        return value.lower()

    def validate_username(self, value):
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError('Username già in uso.')
        return value

    def validate_phone_number(self, value):
        if value and User.objects.filter(phone_number=value).exists():
            raise serializers.ValidationError('Numero di telefono già registrato.')
        return value

    def validate(self, attrs):
        if attrs['password'] != attrs['password_confirm']:
            raise serializers.ValidationError({'password_confirm': 'Le password non corrispondono.'})
        return attrs

    def create(self, validated_data):
        validated_data.pop('password_confirm')
        password = validated_data.pop('password')
        user = User.objects.create_user(
            password=password,
            **validated_data
        )
        # Generate 6-digit verification code
        code = str(random.randint(100000, 999999))
        EmailVerificationToken.objects.create(
            user=user,
            code=code,
            expires_at=timezone.now() + timedelta(hours=24)
        )
        return user


class VerifyEmailSerializer(serializers.Serializer):
    email = serializers.EmailField()
    code = serializers.CharField(max_length=6)


class LoginSerializer(serializers.Serializer):
    email = serializers.EmailField()
    password = serializers.CharField()

    def validate(self, attrs):
        email = attrs.get('email', '').lower()
        password = attrs.get('password')
        user = authenticate(username=email, password=password)
        if not user:
            raise serializers.ValidationError('Credenziali non valide.')
        if not user.is_verified:
            raise serializers.ValidationError('Account non verificato. Controlla la tua email.')
        if not user.is_active:
            raise serializers.ValidationError('Account disattivato.')
        if hasattr(user, 'approval_status') and user.approval_status == 'pending' and not user.is_staff:
            raise serializers.ValidationError('Account in attesa di approvazione da parte dell\'amministratore.')
        if hasattr(user, 'approval_status') and user.approval_status == 'blocked' and not user.is_staff:
            raise serializers.ValidationError('Account bloccato. Contatta l\'amministratore.')
        attrs['user'] = user
        return attrs


class ForgotPasswordSerializer(serializers.Serializer):
    email = serializers.EmailField()


class ResetPasswordSerializer(serializers.Serializer):
    token = serializers.UUIDField()
    new_password = serializers.CharField(min_length=8, validators=[validate_password])
    confirm_password = serializers.CharField()

    def validate(self, attrs):
        if attrs['new_password'] != attrs['confirm_password']:
            raise serializers.ValidationError({'confirm_password': 'Le password non corrispondono.'})
        return attrs


class ChangePasswordSerializer(serializers.Serializer):
    old_password = serializers.CharField()
    new_password = serializers.CharField(min_length=8, validators=[validate_password])
    confirm_password = serializers.CharField()

    def validate(self, attrs):
        if attrs['new_password'] != attrs['confirm_password']:
            raise serializers.ValidationError({'confirm_password': 'Le password non corrispondono.'})
        return attrs


class UserProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = [
            'id', 'email', 'username', 'first_name', 'last_name',
            'phone_number', 'avatar', 'bio', 'country', 'language',
            'is_verified', 'is_online', 'last_seen', 'theme',
            'chat_wallpaper', 'notification_enabled', 'read_receipts',
            'last_seen_visible', 'public_key', 'created_at', 'updated_at'
        ]
        read_only_fields = ['id', 'email', 'is_verified', 'created_at', 'updated_at']

    def validate_language(self, value):
        from django.conf import settings
        supported = [code for code, name in settings.SUPPORTED_LANGUAGES]
        if value not in supported:
            raise serializers.ValidationError(f'Lingua non supportata. Opzioni: {", ".join(supported)}')
        return value


class UserPublicSerializer(serializers.ModelSerializer):
    """Serializer per info pubbliche di un utente (visibile ad altri)"""
    class Meta:
        model = User
        fields = ['id', 'username', 'first_name', 'last_name', 'avatar', 'bio', 'is_online', 'last_seen']
