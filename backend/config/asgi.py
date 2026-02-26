import os
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.base')
django.setup()

from channels.auth import AuthMiddlewareStack
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.security.websocket import AllowedHostsOriginValidator
from django.core.asgi import get_asgi_application

from chat.routing import websocket_urlpatterns as chat_ws
from calls.routing import websocket_urlpatterns as calls_ws
from channels_pub.routing import websocket_urlpatterns as channels_pub_ws

django_asgi_app = get_asgi_application()

application = ProtocolTypeRouter({
    'http': django_asgi_app,
    'websocket': (
        AuthMiddlewareStack(
            URLRouter(
                chat_ws + calls_ws + channels_pub_ws
            )
        )
    ),
})
