import json
import logging
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from channels.db import database_sync_to_async
from .models import Channel, ChannelMember

logger = logging.getLogger(__name__)


class ChannelConsumer(AsyncJsonWebsocketConsumer):
    """
    WebSocket consumer for real-time channel post broadcasting.
    URL: ws/channels/<channel_id>/
    Subscribers connect; when admins publish a post, all connected
    subscribers receive the post in real-time.
    """

    async def connect(self):
        self.channel_id = self.scope['url_route']['kwargs']['channel_id']
        self.room_group_name = f'channel_{self.channel_id}'
        self.user = self.scope.get('user')

        if not self.user or self.user.is_anonymous:
            await self.close(code=4001)
            return

        is_member = await self.check_membership()
        if not is_member:
            await self.close(code=4003)
            return

        await self.channel_layer.group_add(
            self.room_group_name,
            self.channel_name
        )
        await self.accept()
        logger.info(f'User {self.user.id} connected to channel {self.channel_id}')

    async def disconnect(self, close_code):
        await self.channel_layer.group_discard(
            self.room_group_name,
            self.channel_name
        )
        logger.info(f'User {getattr(self, "user", "?")} disconnected from channel {getattr(self, "channel_id", "?")}')

    async def receive_json(self, content, **kwargs):
        # Subscribers cannot send messages in broadcast channels.
        # Only server-side events push data to this group.
        msg_type = content.get('type')
        if msg_type == 'ping':
            await self.send_json({'type': 'pong'})
            return
        await self.send_json({'type': 'error', 'message': 'Broadcast channel: sending not allowed.'})

    # ─── Group event handlers ───

    async def channel_new_post(self, event):
        """Broadcasts a new post to all connected subscribers."""
        await self.send_json({
            'type': 'new_post',
            'post': event['post'],
        })

    async def channel_post_deleted(self, event):
        await self.send_json({
            'type': 'post_deleted',
            'post_id': event['post_id'],
        })

    async def channel_post_pinned(self, event):
        await self.send_json({
            'type': 'post_pinned',
            'post_id': event['post_id'],
            'is_pinned': event['is_pinned'],
        })

    async def channel_poll_update(self, event):
        await self.send_json({
            'type': 'poll_update',
            'post_id': event['post_id'],
            'poll': event['poll'],
        })

    # ─── Helpers ───

    @database_sync_to_async
    def check_membership(self):
        return ChannelMember.objects.filter(
            channel_id=self.channel_id,
            user=self.user,
            is_banned=False,
        ).exists()
