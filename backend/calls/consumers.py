import json
import logging
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from channels.db import database_sync_to_async
from django.utils import timezone
from rest_framework_simplejwt.tokens import AccessToken
from rest_framework_simplejwt.exceptions import TokenError

logger = logging.getLogger(__name__)


class CallSignalingConsumer(AsyncJsonWebsocketConsumer):
    """
    WebSocket consumer for WebRTC call signaling.
    
    Connection: ws://host/ws/calls/?token=<jwt_access_token>
    
    Flow for 1-to-1 call:
    1. Caller sends: {"action": "initiate_call", "conversation_id": "uuid", "call_type": "audio|video"}
    2. Server creates Call record, notifies callee via their user group
    3. Callee sends: {"action": "accept_call", "call_id": "uuid"}
       OR: {"action": "reject_call", "call_id": "uuid"}
    4. If accepted, both exchange SDP offers/answers and ICE candidates:
       {"action": "offer", "call_id": "uuid", "sdp": {...}}
       {"action": "answer", "call_id": "uuid", "sdp": {...}}
       {"action": "ice_candidate", "call_id": "uuid", "candidate": {...}}
    5. Either party sends: {"action": "end_call", "call_id": "uuid"}
    
    Flow for group call:
    Same as 1-to-1 but multiple participants can accept.
    Each pair of participants exchanges SDP/ICE independently.
    """

    async def connect(self):
        self.user = await self._authenticate()
        if not self.user:
            await self.close(code=4001)
            return
        
        self.user_group = f'user_{self.user.id}'
        self.active_calls = set()
        
        await self.channel_layer.group_add(self.user_group, self.channel_name)
        await self.accept()
        logger.info(f'Call WS connected: {self.user.email}')

    async def disconnect(self, close_code):
        if hasattr(self, 'user') and self.user:
            # End any active calls on disconnect
            for call_id in list(self.active_calls):
                await self._handle_end_call({'call_id': str(call_id)})
            
            await self.channel_layer.group_discard(self.user_group, self.channel_name)
            logger.info(f'Call WS disconnected: {self.user.email}')

    async def receive_json(self, content):
        action = content.get('action')
        handlers = {
            'initiate_call': self._handle_initiate,
            'accept_call': self._handle_accept,
            'reject_call': self._handle_reject,
            'offer': self._handle_offer,
            'answer': self._handle_answer,
            'ice_candidate': self._handle_ice_candidate,
            'end_call': self._handle_end_call,
            'toggle_mute': self._handle_toggle_mute,
            'toggle_video': self._handle_toggle_video,
            'toggle_speaker': self._handle_toggle_speaker,
        }
        handler = handlers.get(action)
        if handler:
            try:
                await handler(content)
            except Exception as e:
                logger.error(f'Call error [{action}] {self.user.email}: {e}')
                await self.send_json({'error': str(e), 'action': action})
        else:
            await self.send_json({'error': f'Unknown action: {action}'})

    # ── CALL LIFECYCLE ──

    async def _handle_initiate(self, data):
        """Caller initiates a call"""
        conversation_id = data.get('conversation_id')
        call_type = data.get('call_type', 'audio')
        
        call_data = await self._create_call(conversation_id, call_type)
        if not call_data:
            await self.send_json({'error': 'Impossibile avviare la chiamata.'})
            return
        
        self.active_calls.add(call_data['call_id'])
        
        # Join call-specific group
        call_group = f'call_{call_data["call_id"]}'
        await self.channel_layer.group_add(call_group, self.channel_name)
        
        # Notify all other participants in the conversation
        for participant_id in call_data['participant_ids']:
            if participant_id != self.user.id:
                await self.channel_layer.group_send(f'user_{participant_id}', {
                    'type': 'call.incoming',
                    'call_id': call_data['call_id'],
                    'call_type': call_type,
                    'caller_id': self.user.id,
                    'caller_name': f'{self.user.first_name} {self.user.last_name}',
                    'caller_avatar': self.user.avatar.url if self.user.avatar else None,
                    'conversation_id': str(conversation_id),
                    'is_group_call': call_data['is_group'],
                    'group_name': call_data.get('group_name'),
                })
                
                # Send push notification for call
                try:
                    from notifications.tasks import send_call_notification
                    send_call_notification.delay(
                        recipient_id=participant_id,
                        caller_id=self.user.id,
                        call_id=call_data['call_id'],
                        call_type=call_type,
                    )
                except ImportError:
                    pass
        
        # Confirm to caller
        await self.send_json({
            'type': 'call.initiated',
            'call_id': call_data['call_id'],
            'call_type': call_type,
            'ice_servers': call_data['ice_servers'],
        })
        
        # Auto-miss after 45 seconds if not answered
        # (In production, use Celery delayed task)

    async def _handle_accept(self, data):
        """Callee accepts the call"""
        call_id = data.get('call_id')
        
        result = await self._accept_call(call_id)
        if not result:
            await self.send_json({'error': 'Chiamata non trovata o già terminata.'})
            return
        
        self.active_calls.add(call_id)
        call_group = f'call_{call_id}'
        await self.channel_layer.group_add(call_group, self.channel_name)
        
        # Notify caller that call was accepted
        await self.channel_layer.group_send(f'user_{result["caller_id"]}', {
            'type': 'call.accepted',
            'call_id': call_id,
            'accepted_by': self.user.id,
            'accepted_by_name': f'{self.user.first_name} {self.user.last_name}',
            'ice_servers': result['ice_servers'],
        })
        
        # Send ICE servers to accepter
        await self.send_json({
            'type': 'call.accepted',
            'call_id': call_id,
            'ice_servers': result['ice_servers'],
        })

    async def _handle_reject(self, data):
        """Callee rejects the call"""
        call_id = data.get('call_id')
        reason = data.get('reason', 'rejected')  # rejected or busy
        
        result = await self._reject_call(call_id, reason)
        if result:
            await self.channel_layer.group_send(f'user_{result["caller_id"]}', {
                'type': 'call.rejected',
                'call_id': call_id,
                'rejected_by': self.user.id,
                'reason': reason,
            })

    async def _handle_offer(self, data):
        """Forward SDP offer to the other peer"""
        call_id = data.get('call_id')
        target_user_id = data.get('target_user_id')
        sdp = data.get('sdp')
        
        await self.channel_layer.group_send(f'user_{target_user_id}', {
            'type': 'call.offer',
            'call_id': call_id,
            'sdp': sdp,
            'from_user_id': self.user.id,
        })

    async def _handle_answer(self, data):
        """Forward SDP answer to the caller"""
        call_id = data.get('call_id')
        target_user_id = data.get('target_user_id')
        sdp = data.get('sdp')
        
        await self.channel_layer.group_send(f'user_{target_user_id}', {
            'type': 'call.answer',
            'call_id': call_id,
            'sdp': sdp,
            'from_user_id': self.user.id,
        })

    async def _handle_ice_candidate(self, data):
        """Forward ICE candidate to the other peer"""
        call_id = data.get('call_id')
        target_user_id = data.get('target_user_id')
        candidate = data.get('candidate')
        
        await self.channel_layer.group_send(f'user_{target_user_id}', {
            'type': 'call.ice_candidate',
            'call_id': call_id,
            'candidate': candidate,
            'from_user_id': self.user.id,
        })

    async def _handle_end_call(self, data):
        """End an active call"""
        call_id = data.get('call_id')
        
        result = await self._end_call(call_id)
        if result:
            # Notify all participants
            call_group = f'call_{call_id}'
            await self.channel_layer.group_send(call_group, {
                'type': 'call.ended',
                'call_id': call_id,
                'ended_by': self.user.id,
                'duration': result.get('duration', 0),
            })
            
            # Clean up
            await self.channel_layer.group_discard(call_group, self.channel_name)
            self.active_calls.discard(call_id)

    async def _handle_toggle_mute(self, data):
        call_id = data.get('call_id')
        is_muted = data.get('is_muted', False)
        await self._update_participant_state(call_id, 'is_muted', is_muted)
        call_group = f'call_{call_id}'
        await self.channel_layer.group_send(call_group, {
            'type': 'call.participant_update',
            'call_id': call_id,
            'user_id': self.user.id,
            'field': 'is_muted',
            'value': is_muted,
        })

    async def _handle_toggle_video(self, data):
        call_id = data.get('call_id')
        is_video_off = data.get('is_video_off', False)
        await self._update_participant_state(call_id, 'is_video_off', is_video_off)
        call_group = f'call_{call_id}'
        await self.channel_layer.group_send(call_group, {
            'type': 'call.participant_update',
            'call_id': call_id,
            'user_id': self.user.id,
            'field': 'is_video_off',
            'value': is_video_off,
        })

    async def _handle_toggle_speaker(self, data):
        call_id = data.get('call_id')
        is_speaker_on = data.get('is_speaker_on', False)
        await self._update_participant_state(call_id, 'is_speaker_on', is_speaker_on)

    # ── CHANNEL LAYER EVENT HANDLERS ──

    async def call_incoming(self, event):
        await self.send_json({
            'type': 'call.incoming',
            'call_id': event['call_id'],
            'call_type': event['call_type'],
            'caller_id': event['caller_id'],
            'caller_name': event['caller_name'],
            'caller_avatar': event.get('caller_avatar'),
            'conversation_id': event['conversation_id'],
            'is_group_call': event['is_group_call'],
            'group_name': event.get('group_name'),
        })

    async def call_accepted(self, event):
        await self.send_json({
            'type': 'call.accepted',
            'call_id': event['call_id'],
            'accepted_by': event.get('accepted_by'),
            'accepted_by_name': event.get('accepted_by_name'),
            'ice_servers': event.get('ice_servers', []),
        })

    async def call_rejected(self, event):
        await self.send_json({
            'type': 'call.rejected',
            'call_id': event['call_id'],
            'rejected_by': event.get('rejected_by'),
            'reason': event.get('reason'),
        })

    async def call_offer(self, event):
        await self.send_json({
            'type': 'call.offer',
            'call_id': event['call_id'],
            'sdp': event['sdp'],
            'from_user_id': event['from_user_id'],
        })

    async def call_answer(self, event):
        await self.send_json({
            'type': 'call.answer',
            'call_id': event['call_id'],
            'sdp': event['sdp'],
            'from_user_id': event['from_user_id'],
        })

    async def call_ice_candidate(self, event):
        await self.send_json({
            'type': 'call.ice_candidate',
            'call_id': event['call_id'],
            'candidate': event['candidate'],
            'from_user_id': event['from_user_id'],
        })

    async def call_ended(self, event):
        call_id = event['call_id']
        await self.send_json({
            'type': 'call.ended',
            'call_id': call_id,
            'ended_by': event.get('ended_by'),
            'duration': event.get('duration', 0),
        })
        self.active_calls.discard(call_id)

    async def call_participant_update(self, event):
        if event.get('user_id') == self.user.id:
            return
        await self.send_json({
            'type': 'call.participant_update',
            'call_id': event['call_id'],
            'user_id': event['user_id'],
            'field': event['field'],
            'value': event['value'],
        })

    # ── DATABASE OPERATIONS ──

    @database_sync_to_async
    def _authenticate(self):
        from django.contrib.auth import get_user_model
        User = get_user_model()
        query_string = self.scope.get('query_string', b'').decode()
        params = dict(p.split('=', 1) for p in query_string.split('&') if '=' in p)
        token_str = params.get('token', '')
        if not token_str:
            return None
        try:
            token = AccessToken(token_str)
            return User.objects.get(id=token['user_id'], is_active=True)
        except (TokenError, User.DoesNotExist, KeyError):
            return None

    @database_sync_to_async
    def _create_call(self, conversation_id, call_type):
        from chat.models import Conversation, ConversationParticipant
        from .models import Call, CallParticipant, ICEServer
        
        try:
            conversation = Conversation.objects.get(id=conversation_id)
            participants = list(
                ConversationParticipant.objects.filter(
                    conversation=conversation
                ).values_list('user_id', flat=True)
            )
            
            if self.user.id not in participants:
                return None
            
            is_group = conversation.conv_type == 'group'
            group_name = None
            if is_group:
                group = getattr(conversation, 'group_info', None)
                group_name = group.name if group else None
            
            call = Call.objects.create(
                conversation=conversation,
                call_type=call_type,
                initiated_by=self.user,
                is_group_call=is_group,
            )
            
            # Add caller as participant
            CallParticipant.objects.create(
                call=call, user=self.user, joined_at=timezone.now()
            )
            
            # Get ICE servers
            ice_servers = list(
                ICEServer.objects.filter(is_active=True).values(
                    'server_type', 'url', 'username', 'credential'
                )
            )
            ice_config = []
            for server in ice_servers:
                config = {'urls': server['url']}
                if server['username']:
                    config['username'] = server['username']
                if server['credential']:
                    config['credential'] = server['credential']
                ice_config.append(config)
            
            # Add default STUN if no servers configured
            if not ice_config:
                ice_config = [
                    {'urls': 'stun:stun.l.google.com:19302'},
                    {'urls': 'stun:stun1.l.google.com:19302'},
                ]
            
            return {
                'call_id': str(call.id),
                'participant_ids': participants,
                'is_group': is_group,
                'group_name': group_name,
                'ice_servers': ice_config,
            }
        except Conversation.DoesNotExist:
            return None

    @database_sync_to_async
    def _accept_call(self, call_id):
        from .models import Call, CallParticipant, ICEServer
        
        try:
            call = Call.objects.get(id=call_id, status='ringing')
            call.status = 'ongoing'
            call.started_at = timezone.now()
            call.save(update_fields=['status', 'started_at'])
            
            CallParticipant.objects.update_or_create(
                call=call, user=self.user,
                defaults={'joined_at': timezone.now()}
            )
            
            ice_servers = list(
                ICEServer.objects.filter(is_active=True).values(
                    'server_type', 'url', 'username', 'credential'
                )
            )
            ice_config = []
            for s in ice_servers:
                config = {'urls': s['url']}
                if s['username']:
                    config['username'] = s['username']
                if s['credential']:
                    config['credential'] = s['credential']
                ice_config.append(config)
            if not ice_config:
                ice_config = [
                    {'urls': 'stun:stun.l.google.com:19302'},
                    {'urls': 'stun:stun1.l.google.com:19302'},
                ]
            
            return {
                'caller_id': call.initiated_by_id,
                'ice_servers': ice_config,
            }
        except Call.DoesNotExist:
            return None

    @database_sync_to_async
    def _reject_call(self, call_id, reason):
        from .models import Call
        
        try:
            call = Call.objects.get(id=call_id, status='ringing')
            call.status = reason  # 'rejected' or 'busy'
            call.ended_at = timezone.now()
            call.save(update_fields=['status', 'ended_at'])
            return {'caller_id': call.initiated_by_id}
        except Call.DoesNotExist:
            return None

    @database_sync_to_async
    def _end_call(self, call_id):
        from .models import Call, CallParticipant
        
        try:
            call = Call.objects.get(id=call_id)
            if call.status in ('ended', 'rejected', 'missed', 'failed'):
                return None
            
            call.end_call()
            
            # Update participant
            CallParticipant.objects.filter(
                call=call, user=self.user, left_at__isnull=True
            ).update(left_at=timezone.now())
            
            return {'duration': call.duration}
        except Call.DoesNotExist:
            return None

    @database_sync_to_async
    def _update_participant_state(self, call_id, field, value):
        from .models import CallParticipant
        
        try:
            CallParticipant.objects.filter(
                call_id=call_id, user=self.user
            ).update(**{field: value})
        except Exception:
            pass
