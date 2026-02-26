import uuid
from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.db import models
from django.utils import timezone


class UserManager(BaseUserManager):
    def create_user(self, email, username, password=None, **extra_fields):
        if not email:
            raise ValueError('Email is required')
        email = self.normalize_email(email)
        user = self.model(email=email, username=username, **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email=None, username=None, password=None, **extra_fields):
        extra_fields.setdefault('is_staff', True)
        extra_fields.setdefault('is_superuser', True)
        extra_fields.setdefault('is_verified', True)
        if not email:
            email = extra_fields.get('email', 'admin@securechat.com')
        if not username:
            username = email.split('@')[0]
        return self.create_user(email, username, password, **extra_fields)


class User(AbstractUser):
    email = models.EmailField(unique=True)
    phone_number = models.CharField(max_length=20, unique=True, null=True, blank=True)
    avatar = models.ImageField(upload_to='avatars/', null=True, blank=True)
    bio = models.CharField(max_length=500, blank=True, default='')
    country = models.CharField(max_length=100, blank=True, default='')
    language = models.CharField(max_length=10, default='it')
    is_verified = models.BooleanField(default=False)
    last_seen = models.DateTimeField(null=True, blank=True)
    is_online = models.BooleanField(default=False)
    firebase_token = models.CharField(max_length=500, blank=True, default='')
    public_key = models.TextField(blank=True, default='')

    # Settings
    theme = models.CharField(max_length=20, default='light')
    chat_wallpaper = models.CharField(max_length=200, blank=True, default='')
    notification_enabled = models.BooleanField(default=True)
    read_receipts = models.BooleanField(default=True)
    last_seen_visible = models.BooleanField(default=True)
    lock_pin = models.CharField(max_length=128, blank=True, null=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    objects = UserManager()

    USERNAME_FIELD = 'email'
    REQUIRED_FIELDS = ['username']

    class Meta:
        db_table = 'users'
        ordering = ['-created_at']

    def __str__(self):
        return f'{self.first_name} {self.last_name} ({self.email})'


class EmailVerificationToken(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='verification_tokens')
    code = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    is_used = models.BooleanField(default=False)

    class Meta:
        db_table = 'email_verification_tokens'

    def is_expired(self):
        return timezone.now() > self.expires_at

    def __str__(self):
        return f'Verification for {self.user.email} - {self.code}'


class PasswordResetToken(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='reset_tokens')
    token = models.UUIDField(default=uuid.uuid4, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    is_used = models.BooleanField(default=False)

    class Meta:
        db_table = 'password_reset_tokens'

    def is_expired(self):
        return timezone.now() > self.expires_at

    def __str__(self):
        return f'Reset for {self.user.email} - {self.token}'
