import os
from pathlib import Path
from datetime import timedelta
from celery.schedules import crontab

import environ

env = environ.Env(
    DEBUG=(bool, False),
    DJANGO_ENV=(str, 'development'),
)

BASE_DIR = Path(__file__).resolve().parent.parent.parent

env_file = BASE_DIR / '.env'
if env_file.exists():
    environ.Env.read_env(str(env_file))

# Environment detection
DJANGO_ENV = env('DJANGO_ENV', default='development')  # development | staging | production
IS_PRODUCTION = DJANGO_ENV == 'production'
IS_STAGING = DJANGO_ENV == 'staging'
IS_DEVELOPMENT = DJANGO_ENV == 'development'

# Security
SECRET_KEY = env('DJANGO_SECRET_KEY', default='insecure-dev-key-change-in-production')
DEBUG = env.bool('DEBUG', default=IS_DEVELOPMENT)
ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=['localhost', '127.0.0.1', '0.0.0.0'])

INSTALLED_APPS = [
    'daphne',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    # Third party
    'rest_framework',
    'rest_framework_simplejwt',
    'rest_framework_simplejwt.token_blacklist',
    'corsheaders',
    'storages',
    'channels',
    'django_filters',
    'django_celery_beat',
    # Local apps
    'accounts.apps.AccountsConfig',
    'chat.apps.ChatConfig',
    'calls.apps.CallsConfig',
    'channels_pub.apps.ChannelsPubConfig',
    'encryption.apps.EncryptionConfig',
    'translation.apps.TranslationConfig',
    'notifications.apps.NotificationsConfig',
    'admin_api.apps.AdminApiConfig',
    'security.apps.SecurityConfig',
]

MIDDLEWARE = [
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'accounts.middleware.LastSeenMiddleware',
]

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'
ASGI_APPLICATION = 'config.asgi.application'

# Database — same structure for Docker and DO Managed MySQL
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': env('DB_NAME', default='securechat'),
        'USER': env('DB_USER', default='securechat'),
        'PASSWORD': env('DB_PASSWORD', default='securechat'),
        'HOST': env('DB_HOST', default='db'),
        'PORT': env('DB_PORT', default='3306'),
        'OPTIONS': {
            'charset': 'utf8mb4',
            'init_command': "SET sql_mode='STRICT_TRANS_TABLES'",
            **( {'ssl': {'ca': env('DB_SSL_CA', default='')}} if env('DB_SSL_CA', default='') else {} ),
        },
    }
}

# Auth
AUTH_USER_MODEL = 'accounts.User'

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator', 'OPTIONS': {'min_length': 8}},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# REST Framework
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': (
        'rest_framework_simplejwt.authentication.JWTAuthentication',
    ),
    'DEFAULT_PERMISSION_CLASSES': (
        'rest_framework.permissions.IsAuthenticated',
    ),
    'DEFAULT_PAGINATION_CLASS': 'config.pagination.DefaultCursorPagination',
    'PAGE_SIZE': 50,
    'DEFAULT_FILTER_BACKENDS': (
        'django_filters.rest_framework.DjangoFilterBackend',
        'rest_framework.filters.SearchFilter',
        'rest_framework.filters.OrderingFilter',
    ),
    'DEFAULT_THROTTLE_RATES': {
        'user': '100/hour',
    },
}

# JWT
SIMPLE_JWT = {
    'ACCESS_TOKEN_LIFETIME': timedelta(minutes=60),
    'REFRESH_TOKEN_LIFETIME': timedelta(days=7),
    'ROTATE_REFRESH_TOKENS': True,
    'BLACKLIST_AFTER_ROTATION': True,
    'AUTH_HEADER_TYPES': ('Bearer',),
    'TOKEN_OBTAIN_SERIALIZER': 'accounts.serializers.CustomTokenObtainPairSerializer',
}

# Redis — same structure for Docker and DO Managed Redis
REDIS_URL = env('REDIS_URL', default='redis://redis:6379/0')

CACHES = {
    'default': {
        'BACKEND': 'django_redis.cache.RedisCache',
        'LOCATION': REDIS_URL,
        'OPTIONS': {
            'CLIENT_CLASS': 'django_redis.client.DefaultClient',
            **({'CONNECTION_POOL_KWARGS': {'ssl_cert_reqs': None}} if REDIS_URL.startswith('rediss://') else {}),
        },
    }
}

CHANNEL_LAYERS = {
    'default': {
        'BACKEND': 'channels_redis.core.RedisChannelLayer',
        'CONFIG': {
            'hosts': [REDIS_URL],
            'capacity': 1500,
            'expiry': 10,
            **({'symmetric_encryption_keys': [SECRET_KEY]} if IS_PRODUCTION else {}),
        },
    },
}

# Session
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
SESSION_CACHE_ALIAS = 'default'

# Celery
CELERY_BROKER_URL = env('CELERY_BROKER_URL', default=REDIS_URL)
CELERY_RESULT_BACKEND = env('CELERY_RESULT_BACKEND', default=REDIS_URL)
CELERY_ACCEPT_CONTENT = ['json']
CELERY_TASK_SERIALIZER = 'json'
CELERY_RESULT_SERIALIZER = 'json'
CELERY_TIMEZONE = 'UTC'
CELERY_BROKER_CONNECTION_RETRY_ON_STARTUP = True
CELERY_BEAT_SCHEDULER = 'django_celery_beat.schedulers:DatabaseScheduler'
# When using DatabaseScheduler, add these in Django Admin (Periodic Tasks).
# When using default beat scheduler, this schedule applies:
CELERY_BEAT_SCHEDULE = {
    'publish-scheduled-channel-posts': {
        'task': 'channels_pub.publish_scheduled_posts',
        'schedule': 60.0,  # every 60 seconds
    },
    'update-channel-subscriber-counts': {
        'task': 'channels_pub.update_subscriber_counts',
        'schedule': crontab(minute=0, hour='*/6'),  # every 6 hours
    },
    'cleanup-old-notifications': {
        'task': 'notifications.cleanup_old_notifications',
        'schedule': crontab(minute=0, hour=3),  # daily at 3 AM
        'kwargs': {'days': 90},
    },
    'cleanup-expired-mute-rules': {
        'task': 'notifications.cleanup_expired_mute_rules',
        'schedule': crontab(minute=30, hour='*'),  # every hour at :30
    },
    'cleanup-stale-device-tokens': {
        'task': 'notifications.cleanup_stale_device_tokens',
        'schedule': crontab(minute=0, hour=4),  # daily at 4 AM
        'kwargs': {'days': 60},
    },
    'cleanup-translation-cache': {
        'task': 'translation.cleanup_old_cache',
        'schedule': crontab(minute=0, hour=2, day_of_week=0),  # weekly Sunday 2 AM
        'kwargs': {'days': 30},
    },
    'cleanup-translation-usage-logs': {
        'task': 'translation.cleanup_old_usage_logs',
        'schedule': crontab(minute=0, hour=3, day_of_month=1),  # monthly 1st at 3 AM
        'kwargs': {'days': 90},
    },
}

# Internationalization
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

# Media & Static — local in dev, DigitalOcean Spaces in prod
USE_SPACES = env.bool('USE_SPACES', default=False)

if USE_SPACES:
    AWS_ACCESS_KEY_ID = env('SPACES_ACCESS_KEY')
    AWS_SECRET_ACCESS_KEY = env('SPACES_SECRET_KEY')
    AWS_STORAGE_BUCKET_NAME = env('SPACES_BUCKET_NAME')
    AWS_S3_ENDPOINT_URL = env('SPACES_ENDPOINT_URL')
    AWS_S3_REGION_NAME = env('SPACES_REGION', default='fra1')
    AWS_S3_OBJECT_PARAMETERS = {'CacheControl': 'max-age=86400'}
    AWS_DEFAULT_ACL = 'public-read'
    AWS_S3_SIGNATURE_VERSION = 's3v4'
    AWS_QUERYSTRING_AUTH = False
    STATICFILES_STORAGE = 'config.storage_backends.StaticStorage'
    STATIC_URL = f'{AWS_S3_ENDPOINT_URL}/{AWS_STORAGE_BUCKET_NAME}/static/'
    DEFAULT_FILE_STORAGE = 'config.storage_backends.MediaStorage'
    MEDIA_URL = f'{AWS_S3_ENDPOINT_URL}/{AWS_STORAGE_BUCKET_NAME}/media/'
    MEDIA_ROOT = BASE_DIR / 'media'
    STATIC_ROOT = BASE_DIR / 'staticfiles'
else:
    STATIC_URL = '/static/'
    STATIC_ROOT = BASE_DIR / 'staticfiles'
    MEDIA_URL = '/media/'
    MEDIA_ROOT = BASE_DIR / 'media'

STATICFILES_DIRS = [BASE_DIR / 'static'] if (BASE_DIR / 'static').exists() else []

# File upload
FILE_UPLOAD_MAX_MEMORY_SIZE = 104857600  # 100MB
DATA_UPLOAD_MAX_MEMORY_SIZE = 104857600  # 100MB

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# Translation (Argos Translate)
TRANSLATION_CACHE_TTL = 60 * 60 * 24  # Redis cache TTL: 24 hours
TRANSLATION_MAX_TEXT_LENGTH = 5000  # Max chars per request

# Firebase Cloud Messaging
_firebase_env = env('FIREBASE_CREDENTIALS_PATH', default='')
FIREBASE_CREDENTIALS_PATH = Path(_firebase_env) if _firebase_env else (BASE_DIR / 'config' / 'firebase-service-account.json')
try:
    import firebase_admin
    from firebase_admin import credentials
    if FIREBASE_CREDENTIALS_PATH.exists():
        if not firebase_admin._apps:
            cred = credentials.Certificate(str(FIREBASE_CREDENTIALS_PATH))
            firebase_admin.initialize_app(cred)
        FIREBASE_ENABLED = True
    else:
        FIREBASE_ENABLED = False
except Exception:
    FIREBASE_ENABLED = False

# CORS — for React Admin and Flutter Web
CORS_ALLOW_CREDENTIALS = True
if IS_PRODUCTION:
    CORS_ALLOWED_ORIGINS = env.list('CORS_ALLOWED_ORIGINS', default=[])
else:
    CORS_ALLOW_ALL_ORIGINS = True

# Security headers — production only
if IS_PRODUCTION:
    SECURE_SSL_REDIRECT = True
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_HSTS_SECONDS = 31536000
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD = True
    SECURE_CONTENT_TYPE_NOSNIFF = True
    X_FRAME_OPTIONS = 'DENY'

# Logging
LOG_LEVEL = env('LOG_LEVEL', default='DEBUG' if IS_DEVELOPMENT else 'INFO')
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {process:d} {thread:d} {message}',
            'style': '{',
        },
        'simple': {
            'format': '{levelname} {asctime} {module} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
            'formatter': 'verbose' if IS_PRODUCTION else 'simple',
        },
        'file': {
            'class': 'logging.handlers.RotatingFileHandler',
            'filename': BASE_DIR / 'logs' / 'securechat.log',
            'maxBytes': 10 * 1024 * 1024,
            'backupCount': 5,
            'formatter': 'verbose',
        },
    },
    'root': {
        'handlers': ['console', 'file'] if IS_PRODUCTION else ['console'],
        'level': LOG_LEVEL,
    },
    'loggers': {
        'django': {'handlers': ['console'], 'level': LOG_LEVEL, 'propagate': False},
        'django.db.backends': {'handlers': ['console'], 'level': 'WARNING', 'propagate': False},
        'celery': {
            'handlers': ['console', 'file'] if IS_PRODUCTION else ['console'],
            'level': LOG_LEVEL,
            'propagate': False,
        },
    },
}
(BASE_DIR / 'logs').mkdir(exist_ok=True)

# Sentry — optional
SENTRY_DSN = env('SENTRY_DSN', default='')
if SENTRY_DSN:
    import sentry_sdk
    from sentry_sdk.integrations.django import DjangoIntegration
    from sentry_sdk.integrations.celery import CeleryIntegration
    from sentry_sdk.integrations.redis import RedisIntegration
    sentry_sdk.init(
        dsn=SENTRY_DSN,
        integrations=[DjangoIntegration(), CeleryIntegration(), RedisIntegration()],
        traces_sample_rate=0.1 if IS_PRODUCTION else 1.0,
        send_default_pii=False,
        environment=DJANGO_ENV,
    )

# iOS bundle ID for VoIP push
IOS_BUNDLE_ID = env('IOS_BUNDLE_ID', default='com.securechat.app')

# Supported languages for translation
SUPPORTED_LANGUAGES = [
    ('it', 'Italiano'), ('en', 'English'), ('zh', '中文'),
    ('es', 'Español'), ('fr', 'Français'), ('de', 'Deutsch'),
    ('pt', 'Português'), ('ja', '日本語'), ('ko', '한국어'),
    ('ar', 'العربية'), ('ru', 'Русский'), ('hi', 'हिन्दी'),
    ('tr', 'Türkçe'), ('pl', 'Polski'), ('nl', 'Nederlands'),
]

# ── Email Configuration ──
EMAIL_BACKEND = env('EMAIL_BACKEND', default='django.core.mail.backends.console.EmailBackend')
EMAIL_HOST = env('EMAIL_HOST', default='localhost')
EMAIL_PORT = env.int('EMAIL_PORT', default=587)
EMAIL_USE_TLS = env.bool('EMAIL_USE_TLS', default=True)
EMAIL_HOST_USER = env('EMAIL_HOST_USER', default='')
EMAIL_HOST_PASSWORD = env('EMAIL_HOST_PASSWORD', default='')
DEFAULT_FROM_EMAIL = env('DEFAULT_FROM_EMAIL', default='noreply@securechat.app')
