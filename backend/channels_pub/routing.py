from django.urls import re_path
from . import consumers

websocket_urlpatterns = [
    re_path(r'ws/channels/(?P<channel_id>[0-9a-f-]+)/$', consumers.ChannelConsumer.as_asgi()),
]
