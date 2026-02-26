from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.db import connection
from django.core.cache import cache

@api_view(['GET'])
@permission_classes([AllowAny])
def health_check(request):
    # Check DB
    db_ok = False
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
        db_ok = True
    except Exception:
        pass

    # Check Redis
    redis_ok = False
    try:
        cache.set('health_check', 'ok', 10)
        if cache.get('health_check') == 'ok':
            redis_ok = True
    except Exception:
        pass

    status_code = 200 if (db_ok and redis_ok) else 503
    return Response({
        'status': 'ok' if (db_ok and redis_ok) else 'degraded',
        'db': 'connected' if db_ok else 'disconnected',
        'redis': 'connected' if redis_ok else 'disconnected',
        'version': '1.0.0',
    }, status=status_code)

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/health/', health_check, name='health-check'),
    path('api/auth/', include('accounts.urls')),
    path('api/chat/', include('chat.urls')),
    path('api/calls/', include('calls.urls')),
    path('api/channels/', include('channels_pub.urls')),
    path('api/encryption/', include('encryption.urls')),
    path('api/translation/', include('translation.urls')),
    path('api/notifications/', include('notifications.urls')),
    path('api/admin-panel/', include('admin_api.urls')),
    path('api/security/', include('security.urls')),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
