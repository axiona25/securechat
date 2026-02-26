import json
import logging
from datetime import timedelta
from django.db import models
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from channels.db import database_sync_to_async
from django.utils import timezone
from rest_framework_simplejwt.tokens import AccessToken
from rest_framework_simplejwt.exceptions import TokenError

logger = logging.getLogger(__name__)


class ChatConsumer(AsyncJsonWebsocketConsumer):
    """
    WebSocket consumer for real-time chat messaging.
    
    Connection: ws://host/ws/chat/?token=<jwt_access_token>
    
    Client sends:
        {"action": "send_message", "conversation_id": "uuid", "content_encrypted": "base64", "message_type": "text", ...}
        {"action": "typing", "conversation_id": "uuid"}
        {"action": "stop_typing", "conversation_id": "uuid"}
        {"action": "read_receipt", "message_ids": ["uuid1", "uuid2"]}
        {"action": "delivered", "message_ids": ["uuid1", "uuid2"]}
    
    Server sends:
        {"type": "chat.message", "message": {...}}
        {"type": "typing.indicator", "user_id": 1, "conversation_id": "uuid", "is_typing": true}
        {"type": "status.update", "message_id": "uuid", "status": "read", "user_id": 1}
    """

    async def connect(self):
        """Authenticate via JWT and join user's personal channel group"""
        self.user = await self._authenticate()
        if not self.user:
            await self.close(code=4001)
            return
        
        self.user_group = f'user_{self.user.id}'
        self.conversation_groups = set()
        
        # Join personal group
        await self.channel_layer.group_add(self.user_group, self.channel_name)
        
        # Join all conversation groups
        conversation_ids = await self._get_user_conversations()
        for conv_id in conversation_ids:
            group_name = f'conv_{conv_id}'
            await self.channel_layer.group_add(group_name, self.channel_name)
            self.conversation_groups.add(group_name)
        
        await self.accept()
        
        # Set user online
        await self._set_online(True)
        await self._broadcast_presence(True)

        logger.info(f'WebSocket connected: {self.user.email} ({len(conversation_ids)} conversations)')

    async def disconnect(self, close_code):
        """Clean up on disconnect"""
        if hasattr(self, 'user') and self.user:
            # Leave all groups
            await self.channel_layer.group_discard(self.user_group, self.channel_name)
            for group in self.conversation_groups:
                await self.channel_layer.group_discard(group, self.channel_name)
            
            # Set user offline
            await self._set_online(False)
            await self._broadcast_presence(False)
            logger.info(f'WebSocket disconnected: {self.user.email}')

    async def receive_json(self, content):
        """Route incoming messages to handlers"""
        action = content.get('action')
        
        handlers = {
            'send_message': self._handle_send_message,
            'typing': self._handle_typing,
            'stop_typing': self._handle_stop_typing,
            'read_receipt': self._handle_read_receipt,
            'delivered': self._handle_delivered,
            'edit_message': self._handle_edit_message,
            'delete_message': self._handle_delete_message,
            'react': self._handle_reaction,
        }
        
        handler = handlers.get(action)
        if handler:
            try:
                await handler(content)
            except Exception as e:
                logger.error(f'Error handling {action} from {self.user.email}: {e}')
                await self.send_json({'error': str(e), 'action': action})
        else:
            await self.send_json({'error': f'Unknown action: {action}'})

    # ── MESSAGE HANDLERS ──

    async def _handle_send_message(self, data):
        """Save message and broadcast to conversation participants. Supports E2EE media via attachment_id."""
        conversation_id = data.get('conversation_id')
        message_type = data.get('message_type', 'text')
        content_encrypted = data.get('content_encrypted', '')
        reply_to_id = data.get('reply_to_id')
        attachment_id = data.get('attachment_id')
        encrypted_file_key = data.get('encrypted_file_key', '')
        encrypted_file_keys = data.get('encrypted_file_keys') or {}

        message_data = await self._save_message(
            conversation_id=conversation_id,
            message_type=message_type,
            content_encrypted=content_encrypted,
            reply_to_id=reply_to_id,
            attachment_id=attachment_id,
            encrypted_file_key=encrypted_file_key,
            encrypted_file_keys=encrypted_file_keys,
        )
        
        if not message_data:
            await self.send_json({'error': 'Failed to save message'})
            return
        
        # Broadcast to conversation group
        conv_group = f'conv_{conversation_id}'
        await self.channel_layer.group_send(conv_group, {
            'type': 'chat.message',
            'message': message_data,
            'sender_id': self.user.id,
        })
        
        # Send push notifications to offline participants
        await self._notify_offline_participants(conversation_id, message_data)

    async def _handle_typing(self, data):
        """Broadcast typing indicator (optionally with is_recording for voice)"""
        conversation_id = data.get('conversation_id')
        conv_group = f'conv_{conversation_id}'
        is_recording = data.get('is_recording', False)
        await self.channel_layer.group_send(conv_group, {
            'type': 'typing.indicator',
            'user_id': self.user.id,
            'user_name': f'{self.user.first_name} {self.user.last_name}',
            'conversation_id': str(conversation_id),
            'is_typing': True,
            'is_recording': is_recording,
        })

    async def _handle_stop_typing(self, data):
        """Broadcast stop typing"""
        conversation_id = data.get('conversation_id')
        conv_group = f'conv_{conversation_id}'
        await self.channel_layer.group_send(conv_group, {
            'type': 'typing.indicator',
            'user_id': self.user.id,
            'conversation_id': str(conversation_id),
            'is_typing': False,
            'is_recording': False,
        })

    async def _handle_read_receipt(self, data):
        """Mark messages as read and notify senders"""
        message_ids = data.get('message_ids', [])
        conversation_id = data.get('conversation_id')
        
        sender_ids = await self._update_message_status(message_ids, 'read')
        
        # Notify each original sender
        for sender_id in sender_ids:
            await self.channel_layer.group_send(f'user_{sender_id}', {
                'type': 'status.update',
                'message_ids': message_ids,
                'status': 'read',
                'user_id': self.user.id,
                'conversation_id': str(conversation_id),
                'timestamp': timezone.now().isoformat(),
            })
        
        # Update unread count
        await self._reset_unread_count(conversation_id)

    async def _handle_delivered(self, data):
        """Mark messages as delivered"""
        message_ids = data.get('message_ids', [])
        conversation_id = data.get('conversation_id')
        
        sender_ids = await self._update_message_status(message_ids, 'delivered')
        
        for sender_id in sender_ids:
            await self.channel_layer.group_send(f'user_{sender_id}', {
                'type': 'status.update',
                'message_ids': message_ids,
                'status': 'delivered',
                'user_id': self.user.id,
                'conversation_id': str(conversation_id),
                'timestamp': timezone.now().isoformat(),
            })

    async def _handle_edit_message(self, data):
        """Edit a message (within 15 min window)"""
        message_id = data.get('message_id')
        new_content = data.get('content_encrypted', '')
        
        result = await self._edit_message(message_id, new_content)
        if result:
            conv_group = f'conv_{result["conversation_id"]}'
            await self.channel_layer.group_send(conv_group, {
                'type': 'message.edited',
                'message_id': str(message_id),
                'content_encrypted': new_content,
                'edited_at': result['edited_at'],
                'editor_id': self.user.id,
            })

    async def _handle_delete_message(self, data):
        """Soft delete a message"""
        message_id = data.get('message_id')
        result = await self._delete_message(message_id)
        if result:
            conv_group = f'conv_{result["conversation_id"]}'
            await self.channel_layer.group_send(conv_group, {
                'type': 'message.deleted',
                'message_id': str(message_id),
                'deleted_by': self.user.id,
            })

    async def _handle_reaction(self, data):
        """Add or remove a reaction"""
        message_id = data.get('message_id')
        emoji = data.get('emoji')
        remove = data.get('remove', False)
        
        result = await self._toggle_reaction(message_id, emoji, remove)
        if result:
            conv_group = f'conv_{result["conversation_id"]}'
            await self.channel_layer.group_send(conv_group, {
                'type': 'message.reaction',
                'message_id': str(message_id),
                'user_id': self.user.id,
                'emoji': emoji,
                'action': 'remove' if remove else 'add',
            })

    # ── CHANNEL LAYER EVENT HANDLERS ──

    async def chat_message(self, event):
        """Forward chat message to WebSocket client"""
        # Don't send own messages back
        if event.get('sender_id') == self.user.id:
            return
        await self.send_json({
            'type': 'chat.message',
            'message': event['message'],
        })

    async def typing_indicator(self, event):
        """Forward typing indicator (including is_recording for voice)"""
        if event.get('user_id') == self.user.id:
            return
        await self.send_json({
            'type': 'typing.indicator',
            'user_id': event['user_id'],
            'user_name': event.get('user_name', ''),
            'conversation_id': event['conversation_id'],
            'is_typing': event['is_typing'],
            'is_recording': event.get('is_recording', False),
        })

    async def status_update(self, event):
        """Forward status update (delivered/read)"""
        await self.send_json({
            'type': 'status.update',
            'message_ids': event['message_ids'],
            'status': event['status'],
            'user_id': event['user_id'],
            'conversation_id': event['conversation_id'],
            'timestamp': event['timestamp'],
        })

    async def message_edited(self, event):
        """Forward message edit notification"""
        await self.send_json({
            'type': 'message.edited',
            'message_id': event['message_id'],
            'content_encrypted': event['content_encrypted'],
            'edited_at': event['edited_at'],
        })

    async def message_deleted(self, event):
        """Forward message deletion notification"""
        await self.send_json({
            'type': 'message.deleted',
            'message_id': event['message_id'],
        })

    async def message_reaction(self, event):
        """Forward reaction notification"""
        await self.send_json({
            'type': 'message.reaction',
            'message_id': event['message_id'],
            'user_id': event['user_id'],
            'emoji': event['emoji'],
            'action': event['action'],
        })

    # ── DATABASE OPERATIONS ──

    @database_sync_to_async
    def _authenticate(self):
        """Authenticate user via JWT token from query string"""
        from django.contrib.auth import get_user_model
        User = get_user_model()
        
        query_string = self.scope.get('query_string', b'').decode()
        params = dict(p.split('=', 1) for p in query_string.split('&') if '=' in p)
        token_str = params.get('token', '')
        
        if not token_str:
            return None
        
        try:
            token = AccessToken(token_str)
            user_id = token['user_id']
            user = User.objects.get(id=user_id, is_active=True)
            return user
        except (TokenError, User.DoesNotExist, KeyError) as e:
            logger.warning(f'WebSocket auth failed: {e}')
            return None

    @database_sync_to_async
    def _get_user_conversations(self):
        """Get all conversation IDs for the user"""
        from .models import ConversationParticipant
        return list(
            ConversationParticipant.objects.filter(user=self.user)
            .values_list('conversation_id', flat=True)
        )

    @database_sync_to_async
    def _set_online(self, is_online):
        """Update user online status"""
        self.user.is_online = is_online
        self.user.last_seen = timezone.now()
        self.user.save(update_fields=['is_online', 'last_seen'])

    async def _broadcast_presence(self, is_online):
        """Broadcast presenza a tutti i partecipanti di ogni conversazione dell'utente."""
        try:
            for group_name in self.conversation_groups:
                # group_name è "conv_<uuid>"
                conversation_id = group_name[5:] if group_name.startswith('conv_') else None
                await self.channel_layer.group_send(
                    group_name,
                    {
                        'type': 'presence.update',
                        'user_id': self.user.id,
                        'is_online': is_online,
                        'conversation_id': str(conversation_id) if conversation_id else None,
                    },
                )
        except Exception:
            pass

    async def presence_update(self, event):
        """Invia aggiornamento presenza al client."""
        await self.send_json({
            'type': 'presence.update',
            'user_id': event['user_id'],
            'is_online': event['is_online'],
            'conversation_id': event.get('conversation_id'),
        })

    @database_sync_to_async
    def _save_message(
        self,
        conversation_id,
        message_type,
        content_encrypted,
        reply_to_id=None,
        attachment_id=None,
        encrypted_file_key='',
        encrypted_file_keys=None,
    ):
        """Save a message to the database. Link E2EE attachment if attachment_id provided."""
        from .models import Conversation, Message, MessageStatus, ConversationParticipant, Attachment
        import base64

        encrypted_file_keys = encrypted_file_keys or {}

        try:
            conversation = Conversation.objects.get(id=conversation_id)

            if not ConversationParticipant.objects.filter(
                conversation=conversation, user=self.user
            ).exists():
                return None

            if conversation.conv_type == 'group':
                group = getattr(conversation, 'group_info', None)
                if group and group.only_admins_can_send:
                    participant = ConversationParticipant.objects.get(
                        conversation=conversation, user=self.user
                    )
                    if participant.role != 'admin':
                        return None

            encrypted_bytes = None
            if content_encrypted:
                try:
                    encrypted_bytes = base64.b64decode(content_encrypted)
                except Exception:
                    encrypted_bytes = content_encrypted.encode('utf-8') if isinstance(content_encrypted, str) else content_encrypted

            message = Message.objects.create(
                conversation=conversation,
                sender=self.user,
                message_type=message_type,
                content_encrypted=encrypted_bytes,
                reply_to_id=reply_to_id,
            )

            if attachment_id:
                try:
                    attachment = Attachment.objects.get(id=attachment_id, uploaded_by=self.user)
                    attachment.message = message
                    attachment.save(update_fields=['message'])
                except Attachment.DoesNotExist:
                    pass

            MessageStatus.objects.create(
                message=message, user=self.user, status='sent'
            )

            conversation.last_message = message
            conversation.updated_at = timezone.now()
            conversation.save(update_fields=['last_message', 'updated_at'])

            ConversationParticipant.objects.filter(
                conversation=conversation
            ).exclude(user=self.user).update(
                unread_count=models.F('unread_count') + 1
            )

            payload = {
                'id': str(message.id),
                'conversation_id': str(conversation.id),
                'sender_id': self.user.id,
                'sender_name': f'{self.user.first_name} {self.user.last_name}',
                'sender_avatar': self.user.avatar.url if self.user.avatar else None,
                'message_type': message_type,
                'content_encrypted': content_encrypted,
                'reply_to_id': str(reply_to_id) if reply_to_id else None,
                'is_forwarded': False,
                'created_at': message.created_at.isoformat(),
                'status': 'sent',
            }
            if attachment_id:
                payload['attachment_id'] = str(attachment_id)
                payload['encrypted_file_key'] = encrypted_file_key
                payload['encrypted_file_keys'] = encrypted_file_keys
            return payload

        except Exception as e:
            logger.error(f'Save message error: {e}')
            return None

    @database_sync_to_async
    def _update_message_status(self, message_ids, new_status):
        """Update message status and return sender IDs"""
        from .models import Message, MessageStatus
        
        sender_ids = set()
        for msg_id in message_ids:
            try:
                message = Message.objects.get(id=msg_id)
                sender_ids.add(message.sender_id)
                MessageStatus.objects.update_or_create(
                    message=message, user=self.user,
                    defaults={'status': new_status}
                )
            except Message.DoesNotExist:
                continue
        return list(sender_ids)

    @database_sync_to_async
    def _reset_unread_count(self, conversation_id):
        """Reset unread count for current user in conversation"""
        from .models import ConversationParticipant
        ConversationParticipant.objects.filter(
            conversation_id=conversation_id, user=self.user
        ).update(unread_count=0, last_read_at=timezone.now())

    @database_sync_to_async
    def _edit_message(self, message_id, new_content):
        """Edit a message if within time window"""
        from .models import Message
        import base64
        
        try:
            message = Message.objects.get(id=message_id, sender=self.user)
            if not message.can_edit():
                return None
            
            if new_content:
                try:
                    message.content_encrypted = base64.b64decode(new_content)
                except Exception:
                    message.content_encrypted = new_content.encode('utf-8')
            
            message.is_edited = True
            message.edited_at = timezone.now()
            message.save(update_fields=['content_encrypted', 'is_edited', 'edited_at'])
            
            return {
                'conversation_id': str(message.conversation_id),
                'edited_at': message.edited_at.isoformat(),
            }
        except Message.DoesNotExist:
            return None

    @database_sync_to_async
    def _delete_message(self, message_id):
        """Soft delete a message"""
        from .models import Message
        
        try:
            message = Message.objects.get(id=message_id, sender=self.user)
            message.is_deleted = True
            message.deleted_at = timezone.now()
            message.content_encrypted = None
            message.save(update_fields=['is_deleted', 'deleted_at', 'content_encrypted'])
            return {'conversation_id': str(message.conversation_id)}
        except Message.DoesNotExist:
            return None

    @database_sync_to_async
    def _toggle_reaction(self, message_id, emoji, remove):
        """Add or remove a reaction"""
        from .models import Message, MessageReaction
        
        try:
            message = Message.objects.get(id=message_id)
            if remove:
                MessageReaction.objects.filter(
                    message=message, user=self.user
                ).delete()
            else:
                MessageReaction.objects.update_or_create(
                    message=message, user=self.user,
                    defaults={'emoji': emoji}
                )
            return {'conversation_id': str(message.conversation_id)}
        except Message.DoesNotExist:
            return None

    @database_sync_to_async
    def _notify_offline_participants(self, conversation_id, message_data):
        """Queue push notifications for offline participants"""
        from .models import ConversationParticipant
        from accounts.models import User
        
        offline_participants = ConversationParticipant.objects.filter(
            conversation_id=conversation_id
        ).exclude(
            user=self.user
        ).select_related('user').filter(
            user__is_online=False,
            user__notification_enabled=True,
        )
        
        for participant in offline_participants:
            if participant.muted_until and timezone.now() < participant.muted_until:
                continue
            # Queue Celery task for push notification (implemented in Chapter 9)
            try:
                from notifications.tasks import send_push_notification
                send_push_notification.delay(
                    recipient_id=participant.user_id,
                    sender_id=self.user.id,
                    conversation_id=str(conversation_id),
                    message_preview=message_data.get('message_type', 'message'),
                )
            except ImportError:
                pass  # Notifications module not yet implemented
