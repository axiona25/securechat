"""
Admin panel E2E check API: conversations, calls, key-bundles.
All endpoints require IsAdminUser. Errors are caught, logged, and returned as JSON.
"""
import logging
import traceback
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAdminUser
from rest_framework import status

from admin_api.views import ADMIN_AUTH

logger = logging.getLogger(__name__)


def _json_error(message, status_code=500, detail=None):
    """Return a consistent JSON error response."""
    body = {'error': message}
    if detail is not None:
        body['detail'] = detail
    return Response(body, status=status_code)


def _log_exception(view_name, e):
    """Log full exception for debugging (message + stack trace)."""
    logger.error('[%s] %s: %s', view_name, type(e).__name__, str(e))
    logger.error(traceback.format_exc())


class AdminPanelConversationsView(APIView):
    """GET /api/admin-panel/conversations/ — list all conversations with participants and last activity."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request):
        view_name = 'admin_panel_conversations'
        try:
            from chat.models import Conversation, ConversationParticipant
            from django.db.models import Max

            convs = (
                Conversation.objects
                .prefetch_related('conversation_participants__user')
                .annotate(last_msg_at=Max('messages__created_at'))
                .order_by('-updated_at')
            )
            out = []
            for c in convs:
                participants = []
                for cp in c.conversation_participants.select_related('user').all():
                    u = cp.user
                    participants.append({
                        'id': u.id,
                        'username': getattr(u, 'username', u.email),
                        'full_name': u.get_full_name() or u.email or str(u.id),
                        'last_seen': u.last_seen.isoformat() if getattr(u, 'last_seen', None) else None,
                    })
                name = f"{c.conv_type.title()} conversation"
                if c.conv_type == 'private' and len(participants) >= 2:
                    names = [p['full_name'] or p['username'] for p in participants[:2]]
                    name = ' & '.join(names)
                last_activity = getattr(c, 'last_msg_at', None) or c.updated_at
                out.append({
                    'id': str(c.id),
                    'name': name,
                    'is_group': c.conv_type == 'group',
                    'created_at': c.created_at.isoformat(),
                    'last_message_at': c.last_message_id and str(c.last_message_id),
                    'creator': None,
                    'participants': participants,
                    'last_activity': last_activity.isoformat() if last_activity else None,
                })
            return Response({'conversations': out})
        except Exception as e:
            _log_exception(view_name, e)
            return _json_error(
                'Failed to list conversations',
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=str(e)
            )


class AdminPanelConversationMessagesView(APIView):
    """GET /api/admin-panel/conversations/<uuid:conversation_id>/messages/ — messages with content_encrypted (hex)."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request, conversation_id):
        view_name = 'admin_panel_conversation_messages'
        try:
            from chat.models import Conversation, Message

            conv = Conversation.objects.get(id=conversation_id)
        except Exception as e:
            if e.__class__.__name__ == 'DoesNotExist':
                return _json_error('Conversation not found', status_code=status.HTTP_404_NOT_FOUND)
            _log_exception(view_name, e)
            return _json_error('Failed to load conversation', status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        try:
            limit = int(request.query_params.get('limit', 100))
            offset = int(request.query_params.get('offset', 0))
        except (TypeError, ValueError):
            limit, offset = 100, 0

        try:
            messages = (
                Message.objects.filter(conversation=conv)
                .select_related('sender')
                .order_by('created_at')[offset:offset + limit]
            )
            out = []
            for m in messages:
                raw = m.content_encrypted
                if raw is not None:
                    try:
                        content_encrypted = raw.hex() if isinstance(raw, bytes) else str(raw)
                    except Exception:
                        content_encrypted = str(raw)[:500]
                else:
                    content_encrypted = ''
                content_for_translation = getattr(m, 'content_for_translation', '') or ''
                out.append({
                    'id': str(m.id),
                    'sender': {
                        'id': m.sender.id,
                        'username': getattr(m.sender, 'username', m.sender.email),
                        'full_name': m.sender.get_full_name() or m.sender.email or str(m.sender.id),
                    },
                    'timestamp': m.created_at.isoformat(),
                    'message_type': getattr(m, 'message_type', 'text') or 'text',
                    'content_encrypted': content_encrypted,
                    'content_for_translation': content_for_translation or None,
                })
            total = Message.objects.filter(conversation=conv).count()
            return Response({
                'chat_id': str(conv.id),
                'messages': out,
                'total': total,
                'limit': limit,
                'offset': offset,
            })
        except Exception as e:
            _log_exception(view_name, e)
            return _json_error(
                'Failed to list messages',
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=str(e)
            )


class AdminPanelCallsView(APIView):
    """GET /api/admin-panel/calls/ — list all calls with caller, callee, type, status, duration."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request):
        view_name = 'admin_panel_calls'
        try:
            from calls.models import Call, CallParticipant
            from chat.models import ConversationParticipant

            calls = Call.objects.select_related('initiated_by', 'conversation').prefetch_related('participants__user').order_by('-created_at')
            out = []
            for call in calls:
                caller = call.initiated_by
                callee = None
                other_participants = ConversationParticipant.objects.filter(conversation=call.conversation).exclude(user=caller).select_related('user')[:1]
                if other_participants:
                    callee = other_participants[0].user
                duration_seconds = getattr(call, 'duration', 0) or 0
                out.append({
                    'id': str(call.id),
                    'session_id': str(call.id),
                    'caller': {
                        'id': caller.id,
                        'username': getattr(caller, 'username', caller.email),
                        'full_name': caller.get_full_name() or caller.email or str(caller.id),
                    },
                    'callee': {
                        'id': callee.id,
                        'username': getattr(callee, 'username', callee.email),
                        'full_name': callee.get_full_name() or callee.email or str(callee.id),
                    } if callee else {'id': None, 'username': '-', 'full_name': '-'},
                    'call_type': getattr(call, 'call_type', 'audio') or 'audio',
                    'status': call.status,
                    'duration_seconds': duration_seconds,
                    'created_at': call.created_at.isoformat(),
                    'answered_at': call.started_at.isoformat() if getattr(call, 'started_at', None) else None,
                    'ended_at': call.ended_at.isoformat() if getattr(call, 'ended_at', None) else None,
                })
            return Response({'calls': out})
        except Exception as e:
            _log_exception(view_name, e)
            return _json_error(
                'Failed to list calls',
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=str(e)
            )


class AdminPanelCallDetailView(APIView):
    """GET /api/admin-panel/calls/<uuid:call_id>/ — call detail with participants and timeline."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request, call_id):
        view_name = 'admin_panel_call_detail'
        try:
            from calls.models import Call, CallParticipant
            from chat.models import ConversationParticipant

            call = Call.objects.select_related('initiated_by', 'conversation').prefetch_related('participants__user').get(id=call_id)
        except Exception as e:
            if e.__class__.__name__ == 'DoesNotExist':
                return _json_error('Call not found', status_code=status.HTTP_404_NOT_FOUND)
            _log_exception(view_name, e)
            return _json_error('Failed to load call', status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        try:
            caller = call.initiated_by
            callee = None
            other_participants = ConversationParticipant.objects.filter(conversation=call.conversation).exclude(user=caller).select_related('user')
            if other_participants:
                callee = other_participants[0].user
            participants = []
            for p in call.participants.select_related('user').all():
                u = p.user
                participants.append({
                    'user_id': u.id,
                    'username': getattr(u, 'username', u.email),
                    'full_name': u.get_full_name() or u.email or str(u.id),
                    'joined_at': p.joined_at.isoformat() if getattr(p, 'joined_at', None) else None,
                    'left_at': p.left_at.isoformat() if getattr(p, 'left_at', None) else None,
                })
            timeline = [{'event': 'created', 'at': call.created_at.isoformat()}]
            if getattr(call, 'started_at', None):
                timeline.append({'event': 'started', 'at': call.started_at.isoformat()})
            if getattr(call, 'ended_at', None):
                timeline.append({'event': 'ended', 'at': call.ended_at.isoformat()})
            duration_seconds = getattr(call, 'duration', 0) or 0
            return Response({
                'id': str(call.id),
                'session_id': str(call.id),
                'caller': {
                    'id': caller.id,
                    'username': getattr(caller, 'username', caller.email),
                    'full_name': caller.get_full_name() or caller.email or str(caller.id),
                },
                'callee': {
                    'id': callee.id,
                    'username': getattr(callee, 'username', callee.email),
                    'full_name': callee.get_full_name() or callee.email or str(callee.id),
                } if callee else {'id': None, 'username': '-', 'full_name': '-'},
                'call_type': getattr(call, 'call_type', 'audio') or 'audio',
                'status': call.status,
                'duration_seconds': duration_seconds,
                'end_reason': getattr(call, 'end_reason', None),
                'participants': participants,
                'timeline': timeline,
                'sdp_offer': None,
                'sdp_answer': None,
                'created_at': call.created_at.isoformat(),
                'answered_at': call.started_at.isoformat() if getattr(call, 'started_at', None) else None,
                'ended_at': call.ended_at.isoformat() if getattr(call, 'ended_at', None) else None,
            })
        except Exception as e:
            _log_exception(view_name, e)
            return _json_error(
                'Failed to build call detail',
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=str(e)
            )


class AdminPanelKeyBundlesView(APIView):
    """GET /api/admin-panel/key-bundles/ — list key bundles (identity_key, signed_prekey, prekeys count)."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request):
        view_name = 'admin_panel_key_bundles'
        try:
            from encryption.models import UserKeyBundle, OneTimePreKey, SessionKey
            from django.db.models import Count

            bundles = UserKeyBundle.objects.select_related('user').all()
            out = []
            for b in bundles:
                u = b.user
                identity_key = b.identity_key_public
                if identity_key is not None:
                    try:
                        identity_key = identity_key.hex() if isinstance(identity_key, bytes) else str(identity_key)
                    except Exception:
                        identity_key = str(identity_key)[:200]
                else:
                    identity_key = ''
                signed_prekey = b.signed_prekey_public
                if signed_prekey is not None:
                    try:
                        signed_prekey = signed_prekey.hex() if isinstance(signed_prekey, bytes) else str(signed_prekey)
                    except Exception:
                        signed_prekey = str(signed_prekey)[:200]
                else:
                    signed_prekey = ''
                otpk_count = OneTimePreKey.objects.filter(user=u, is_used=False).count()
                session_count = SessionKey.objects.filter(user=u).count()
                out.append({
                    'user_id': u.id,
                    'username': getattr(u, 'username', u.email),
                    'full_name': u.get_full_name() or u.email or str(u.id),
                    'created_at': b.created_at.isoformat(),
                    'updated_at': b.uploaded_at.isoformat() if getattr(b, 'uploaded_at', None) else b.created_at.isoformat(),
                    'identity_key': identity_key,
                    'signed_prekey': signed_prekey,
                    'one_time_prekeys_count': otpk_count,
                    'session_keys_count': session_count,
                })
            return Response({'key_bundles': out})
        except Exception as e:
            _log_exception(view_name, e)
            return _json_error(
                'Failed to list key bundles',
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=str(e)
            )
