import os
import re
import subprocess
import uuid
import bcrypt
from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from datetime import timedelta
from django.conf import settings
from django.http import FileResponse, HttpResponse, JsonResponse
from django.utils import timezone
from django.db import models
from django.db.models import Q, Prefetch, Count
from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework.parsers import MultiPartParser, FormParser
from rest_framework.pagination import CursorPagination
from .models import (
    Conversation, ConversationParticipant, Message, Attachment,
    MessageStatus, MessageReaction, LocationShare, ContactShare,
    CalendarEvent, Group, Story, StoryView
)
from .serializers import (
    ConversationListSerializer, ConversationDetailSerializer,
    MessageSerializer, CreatePrivateConversationSerializer,
    CreateGroupSerializer, LockChatSerializer, StorySerializer,
    AttachmentSerializer
)


class MessagePagination(CursorPagination):
    page_size = 50
    ordering = '-created_at'
    cursor_query_param = 'cursor'


class ConversationListView(APIView):
    """
    GET  /api/chat/conversations/ — list conversations for current user.
    POST /api/chat/conversations/ — create private conversation (body: participants, conv_type).
    Alternative: POST /api/chat/conversations/create/ with body {"user_id": <int>} (see CreatePrivateConversationView).
    """
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """List all conversations for current user, ordered by last activity"""
        conversations = Conversation.objects.filter(
            conversation_participants__user=request.user,
            conversation_participants__is_hidden=False,
        ).select_related('last_message', 'last_message__sender').prefetch_related(
            'conversation_participants__user',
            'group_info',
        ).order_by('-updated_at')

        # Search filter
        search = request.query_params.get('search', '')
        if search:
            conversations = conversations.filter(
                Q(group_info__name__icontains=search) |
                Q(conversation_participants__user__first_name__icontains=search) |
                Q(conversation_participants__user__last_name__icontains=search)
            ).distinct()

        serializer = ConversationListSerializer(
            conversations, many=True, context={'request': request}
        )
        return Response(serializer.data)

    def post(self, request):
        """Create a private conversation. Body: {"participants": [user_id], "conv_type": "private"}"""
        participants = request.data.get('participants')
        conv_type = request.data.get('conv_type', 'private')

        # ── GROUP CREATION ──
        if conv_type == 'group':
            name = request.data.get('name', '').strip()
            if not name:
                return Response({'error': 'Il nome del gruppo è obbligatorio.'}, status=status.HTTP_400_BAD_REQUEST)

            participants = request.data.get('participants', [])
            if len(participants) < 2:
                return Response({'error': 'Servono almeno 2 partecipanti.'}, status=status.HTTP_400_BAD_REQUEST)

            from django.contrib.auth import get_user_model
            User = get_user_model()
            valid_users = User.objects.filter(id__in=participants)
            if valid_users.count() != len(participants):
                return Response({'error': 'Uno o più utenti non esistono.'}, status=status.HTTP_400_BAD_REQUEST)

            conversation = Conversation.objects.create(conv_type='group')
            from chat.models import Group
            Group.objects.create(
                conversation=conversation,
                name=name,
                description=request.data.get('description', ''),
                created_by=request.user,
            )
            ConversationParticipant.objects.create(conversation=conversation, user=request.user, role='admin')
            for user in valid_users:
                if user.id != request.user.id:
                    ConversationParticipant.objects.create(conversation=conversation, user=user, role='member')

            serializer = ConversationDetailSerializer(conversation, context={'request': request})
            return Response(serializer.data, status=status.HTTP_201_CREATED)

        if not isinstance(participants, list) or len(participants) != 1:
            return Response(
                {'error': 'Per conversazioni private invia participants: [user_id] con un solo id.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        other_user_id = participants[0]
        if isinstance(other_user_id, str):
            try:
                other_user_id = int(other_user_id)
            except (ValueError, TypeError):
                return Response({'error': 'user_id non valido.'}, status=status.HTTP_400_BAD_REQUEST)

        if other_user_id == request.user.id:
            return Response(
                {'error': 'Non puoi chattare con te stesso.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        if conv_type != 'private':
            return Response(
                {'error': 'Solo conv_type=private è supportato da questo endpoint.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Cerca conversazione privata che ha other_user come partecipante (indipendentemente da is_hidden)
        other_conv_ids = ConversationParticipant.objects.filter(
            user_id=other_user_id,
            conversation__conv_type='private'
        ).values('conversation_id')

        # Cerca se request.user è partecipante (anche hidden)
        existing = Conversation.objects.filter(
            id__in=other_conv_ids,
            conversation_participants__user=request.user
        ).first()

        if existing:
            session_reset = False
            # Riattiva entrambi i partecipanti se hidden
            for uid in [request.user.id, other_user_id]:
                participant, created = ConversationParticipant.objects.get_or_create(
                    conversation=existing,
                    user_id=uid,
                    defaults={'role': 'member', 'cleared_at': timezone.now()}
                )
                if not created and participant.is_hidden:
                    participant.is_hidden = False
                    participant.cleared_at = timezone.now()
                    participant.save()
                    session_reset = True
            serializer = ConversationDetailSerializer(existing, context={'request': request})
            data = dict(serializer.data)
            data['session_reset'] = session_reset
            if session_reset:
                channel_layer = get_channel_layer()
                other_participant = ConversationParticipant.objects.filter(
                    conversation=existing,
                    is_hidden=False,
                ).exclude(user=request.user).first()
                if other_participant:
                    user_group = f'user_{other_participant.user.id}'
                    async_to_sync(channel_layer.group_send)(
                        user_group,
                        {
                            'type': 'session.reset',
                            'conversation_id': str(existing.id),
                            'reset_user_id': request.user.id,
                        },
                    )
            return Response(data, status=status.HTTP_200_OK)

        # Nessuna conversazione esistente — crea nuova
        conversation = Conversation.objects.create(conv_type='private')
        ConversationParticipant.objects.create(conversation=conversation, user=request.user, role='member')
        ConversationParticipant.objects.create(conversation=conversation, user_id=other_user_id, role='member')

        serializer = ConversationDetailSerializer(conversation, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class CreatePrivateConversationView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        """Create a private 1-on-1 conversation"""
        serializer = CreatePrivateConversationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        other_user_id = serializer.validated_data['user_id']

        if other_user_id == request.user.id:
            return Response({'error': 'Non puoi chattare con te stesso.'},
                          status=status.HTTP_400_BAD_REQUEST)

        # Cerca conversazione privata che ha other_user come partecipante (indipendentemente da is_hidden)
        other_conv_ids = ConversationParticipant.objects.filter(
            user_id=other_user_id,
            conversation__conv_type='private'
        ).values('conversation_id')

        # Cerca se request.user è partecipante (anche hidden)
        existing = Conversation.objects.filter(
            id__in=other_conv_ids,
            conversation_participants__user=request.user
        ).first()

        if existing:
            session_reset = False
            # Riattiva entrambi i partecipanti se hidden
            for uid in [request.user.id, other_user_id]:
                participant, created = ConversationParticipant.objects.get_or_create(
                    conversation=existing,
                    user_id=uid,
                    defaults={'role': 'member', 'cleared_at': timezone.now()}
                )
                if not created and participant.is_hidden:
                    participant.is_hidden = False
                    participant.cleared_at = timezone.now()
                    participant.save()
                    session_reset = True
            serializer = ConversationDetailSerializer(existing, context={'request': request})
            data = dict(serializer.data)
            data['session_reset'] = session_reset
            if session_reset:
                channel_layer = get_channel_layer()
                other_participant = ConversationParticipant.objects.filter(
                    conversation=existing,
                    is_hidden=False,
                ).exclude(user=request.user).first()
                if other_participant:
                    user_group = f'user_{other_participant.user.id}'
                    async_to_sync(channel_layer.group_send)(
                        user_group,
                        {
                            'type': 'session.reset',
                            'conversation_id': str(existing.id),
                            'reset_user_id': request.user.id,
                        },
                    )
            return Response(data, status=status.HTTP_200_OK)

        # Nessuna conversazione esistente — crea nuova
        conversation = Conversation.objects.create(conv_type='private')
        ConversationParticipant.objects.create(conversation=conversation, user=request.user, role='member')
        ConversationParticipant.objects.create(conversation=conversation, user_id=other_user_id, role='member')

        serializer = ConversationDetailSerializer(conversation, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class ConversationDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, conversation_id):
        """Get conversation details"""
        try:
            conversation = Conversation.objects.prefetch_related(
                'conversation_participants__user', 'group_info'
            ).get(id=conversation_id, conversation_participants__user=request.user)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        serializer = ConversationDetailSerializer(conversation, context={'request': request})
        return Response(serializer.data)

    def patch(self, request, conversation_id):
        """Modifica nome/descrizione del gruppo (solo admin)."""
        try:
            conversation = Conversation.objects.get(id=conversation_id)
            my_part = ConversationParticipant.objects.get(conversation=conversation, user=request.user)
            if my_part.role != 'admin':
                return Response({'error': 'Solo gli admin possono modificare'}, status=status.HTTP_403_FORBIDDEN)
            try:
                group = conversation.group_info
            except Group.DoesNotExist:
                return Response({'error': 'Non è un gruppo'}, status=status.HTTP_400_BAD_REQUEST)
            name = request.data.get('name')
            description = request.data.get('description')
            if name is not None:
                group.name = name
            if description is not None:
                group.description = description
            group.save()
            serializer = ConversationDetailSerializer(conversation, context={'request': request})
            return Response(serializer.data, status=status.HTTP_200_OK)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata'}, status=status.HTTP_404_NOT_FOUND)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Non sei partecipante'}, status=status.HTTP_403_FORBIDDEN)


class ConversationParticipantsView(APIView):
    """Gestione partecipanti di una conversazione di gruppo."""
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Aggiunge un membro al gruppo (solo admin)."""
        try:
            conversation = Conversation.objects.get(id=conversation_id)
            my_part = ConversationParticipant.objects.get(conversation=conversation, user=request.user)
            if my_part.role != 'admin':
                return Response({'error': 'Solo admin e moderatori possono aggiungere membri'}, status=status.HTTP_403_FORBIDDEN)
            user_id = request.data.get('user_id')
            if not user_id:
                return Response({'error': 'user_id richiesto'}, status=status.HTTP_400_BAD_REQUEST)
            if ConversationParticipant.objects.filter(conversation=conversation, user_id=user_id).exists():
                return Response({'error': 'Utente già nel gruppo'}, status=status.HTTP_400_BAD_REQUEST)
            ConversationParticipant.objects.create(conversation=conversation, user_id=user_id, role='member')
            return Response({'added': True}, status=status.HTTP_201_CREATED)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata'}, status=status.HTTP_404_NOT_FOUND)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Non sei partecipante'}, status=status.HTTP_403_FORBIDDEN)


class ConversationParticipantDetailView(APIView):
    """Modifica ruolo o rimuovi un partecipante."""
    permission_classes = [IsAuthenticated]

    def patch(self, request, conversation_id, user_id):
        """Cambia ruolo di un partecipante (solo admin)."""
        try:
            conversation = Conversation.objects.get(id=conversation_id)
            my_part = ConversationParticipant.objects.get(conversation=conversation, user=request.user)
            if my_part.role != 'admin':
                return Response({'error': 'Solo gli admin possono cambiare ruoli'}, status=status.HTTP_403_FORBIDDEN)
            target = ConversationParticipant.objects.get(conversation=conversation, user_id=user_id)
            new_role = request.data.get('role', target.role)
            if new_role not in ('admin', 'member'):
                return Response({'error': 'Ruolo non valido'}, status=status.HTTP_400_BAD_REQUEST)
            target.role = new_role
            target.save()
            return Response({'role': new_role}, status=status.HTTP_200_OK)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata'}, status=status.HTTP_404_NOT_FOUND)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Partecipante non trovato'}, status=status.HTTP_404_NOT_FOUND)

    def delete(self, request, conversation_id, user_id):
        """Rimuovi un partecipante (solo admin)."""
        try:
            conversation = Conversation.objects.get(id=conversation_id)
            my_part = ConversationParticipant.objects.get(conversation=conversation, user=request.user)
            if my_part.role != 'admin':
                return Response({'error': 'Solo gli admin possono rimuovere membri'}, status=status.HTTP_403_FORBIDDEN)
            target = ConversationParticipant.objects.get(conversation=conversation, user_id=user_id)
            if target.user == request.user:
                return Response({'error': 'Non puoi rimuovere te stesso'}, status=status.HTTP_400_BAD_REQUEST)
            target.delete()
            return Response({'removed': True}, status=status.HTTP_200_OK)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata'}, status=status.HTTP_404_NOT_FOUND)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Partecipante non trovato'}, status=status.HTTP_404_NOT_FOUND)

    def put(self, request, conversation_id, user_id):
        """Blocca o sblocca un partecipante (solo admin)."""
        try:
            conversation = Conversation.objects.get(id=conversation_id)
            my_part = ConversationParticipant.objects.get(conversation=conversation, user=request.user)
            if my_part.role != 'admin':
                return Response({'error': 'Solo gli admin possono bloccare'}, status=status.HTTP_403_FORBIDDEN)
            target = ConversationParticipant.objects.get(conversation=conversation, user_id=user_id)
            action = request.data.get('action', 'block')
            target.is_blocked = (action == 'block')
            target.save()
            return Response({'is_blocked': target.is_blocked}, status=status.HTTP_200_OK)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata'}, status=status.HTTP_404_NOT_FOUND)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Partecipante non trovato'}, status=status.HTTP_404_NOT_FOUND)


class MessageListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, conversation_id):
        """List messages in a conversation with cursor pagination"""
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Accesso negato.'}, status=status.HTTP_403_FORBIDDEN)

        messages = Message.objects.filter(
            conversation_id=conversation_id
        ).select_related('sender').prefetch_related(
            'attachments', 'statuses', 'reactions',
            'location', 'shared_contact', 'calendar_event',
            'reply_to__sender',
        ).order_by('-created_at')

        if participant.cleared_at:
            messages = messages.filter(created_at__gt=participant.cleared_at)

        paginator = MessagePagination()
        page = paginator.paginate_queryset(messages, request)
        serializer = MessageSerializer(page, many=True, context={'request': request})
        return paginator.get_paginated_response(serializer.data)

    def post(self, request, conversation_id):
        """Send a message via REST (alternative to WebSocket)"""
        if not ConversationParticipant.objects.filter(
            conversation_id=conversation_id, user=request.user
        ).exists():
            return Response({'error': 'Accesso negato.'}, status=status.HTTP_403_FORBIDDEN)

        conversation = Conversation.objects.get(id=conversation_id)
        # Controlla se l'utente è bloccato nel gruppo
        if conversation.conv_type == 'group':
            try:
                participant = ConversationParticipant.objects.get(conversation=conversation, user=request.user)
                if participant.is_blocked:
                    return Response(
                        {'error': 'Sei stato bloccato in questo gruppo. Non puoi inviare messaggi.'},
                        status=status.HTTP_403_FORBIDDEN
                    )
            except ConversationParticipant.DoesNotExist:
                pass

        message_type = request.data.get('message_type', 'text')
        content_plain = request.data.get('content', '')
        content_encrypted = request.data.get('content_encrypted', '')
        reply_to_id = request.data.get('reply_to_id')
        attachment_ids = request.data.get('attachment_ids') or []

        import base64
        encrypted_bytes = None
        if content_encrypted:
            try:
                encrypted_bytes = base64.b64decode(content_encrypted)
            except Exception:
                encrypted_bytes = content_encrypted.encode('utf-8')
        elif content_plain:
            # Plaintext from client (no E2EE yet): store for display and search
            encrypted_bytes = content_plain.encode('utf-8')

        message = Message.objects.create(
            conversation_id=conversation_id,
            sender=request.user,
            message_type=message_type,
            content_encrypted=encrypted_bytes,
            content_for_translation=content_plain or '',
            reply_to_id=reply_to_id,
        )

        # ── Salva payload cifrati per destinatario (E2E gruppi fan-out) ──
        recipients_encrypted = request.data.get('recipients_encrypted')
        if recipients_encrypted and isinstance(recipients_encrypted, dict):
            from chat.models import MessageRecipient
            for user_id_str, encrypted_b64 in recipients_encrypted.items():
                try:
                    user_id = int(user_id_str)
                    encrypted_bytes_recipient = base64.b64decode(encrypted_b64)
                    MessageRecipient.objects.create(
                        message=message,
                        user_id=user_id,
                        content_encrypted=encrypted_bytes_recipient,
                    )
                except (ValueError, Exception) as e:
                    import logging
                    logging.getLogger(__name__).error(f'Failed to save recipient payload for user {user_id_str}: {e}')

        for att_id in attachment_ids:
            try:
                att = Attachment.objects.filter(id=att_id).first()
                print(f'[ATTACH-DEBUG] att_id={att_id}, found={att is not None}, '
                      f'owner={att.uploaded_by_id if att else None}, '
                      f'msg={att.message_id if att else None}')
                updated = Attachment.objects.filter(
                    id=att_id,
                    uploaded_by=request.user,
                    message__isnull=True,
                ).update(message=message)
                print(f'[ATTACH-DEBUG] updated={updated}')
            except (ValueError, TypeError) as e:
                print(f'[ATTACH-DEBUG] error={e}')

        MessageStatus.objects.create(message=message, user=request.user, status='sent')

        # Update conversation
        Conversation.objects.filter(id=conversation_id).update(
            last_message=message, updated_at=timezone.now()
        )

        # Increment unread_count for all participants except sender
        ConversationParticipant.objects.filter(
            conversation_id=conversation_id
        ).exclude(
            user=request.user
        ).update(
            unread_count=models.F('unread_count') + 1
        )

        # Non inviare broadcast per messaggi con allegati legacy: sarà l'endpoint di upload a farlo
        attachment_ids = request.data.get('attachment_ids') or []
        has_legacy_attachment = not attachment_ids and message_type in ('image', 'video', 'audio', 'voice', 'file')

        if not has_legacy_attachment:
            try:
                channel_layer = get_channel_layer()
                message_data = MessageSerializer(message, context={'request': request}).data
                if channel_layer and recipients_encrypted and isinstance(recipients_encrypted, dict):
                    # E2E gruppo: invia a ogni partecipante il suo payload cifrato
                    conversation = message.conversation
                    participants = conversation.conversation_participants.select_related('user').all()
                    for cp in participants:
                        if cp.user_id == request.user.id:
                            continue  # Non inviare al mittente
                        user_group = f'user_{cp.user_id}'
                        per_user_payload = dict(message_data)
                        user_enc = recipients_encrypted.get(str(cp.user_id), '')
                        per_user_payload['content_encrypted'] = user_enc
                        per_user_payload.pop('content', None)  # Rimuovi plaintext
                        async_to_sync(channel_layer.group_send)(user_group, {
                            'type': 'chat.message',
                            'message': per_user_payload,
                            'sender_id': request.user.id,
                        })
                elif channel_layer:
                    # Messaggi normali (testo gruppi in chiaro, chat private)
                    conv_group = f'conv_{conversation_id}'
                    payload = {
                        'type': 'chat.message',
                        'message': message_data,
                        'sender_id': request.user.id,
                    }
                    if content_plain:
                        payload['content'] = content_plain
                    async_to_sync(channel_layer.group_send)(conv_group, payload)
            except Exception as e:
                print(f'[MSG-BROADCAST] group_send error: {e}')

        # Invia notifica push ai partecipanti offline
        try:
            from chat.push_notifications import send_push_to_conversation_participants
            sender_name = f"{request.user.first_name} {request.user.last_name}".strip() or request.user.username
            if conversation.conv_type == 'group':
                group_name = 'Gruppo'
                try:
                    group_name = conversation.group_info.name
                except Exception:
                    pass
                push_title = group_name
                push_body = f"{sender_name}: Nuovo messaggio"
            else:
                push_title = sender_name
                push_body = "Nuovo messaggio"
            push_data = {
                'conversation_id': str(conversation.id),
                'message_type': message_type or 'text',
            }
            send_push_to_conversation_participants(conversation, request.user, push_title, push_body, push_data)
        except Exception as e:
            import logging
            logging.getLogger(__name__).error('Push notification error: %s', e)

        serializer = MessageSerializer(message, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class MarkAsReadView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Mark all messages in conversation as read for current user."""
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Accesso negato.'}, status=status.HTTP_403_FORBIDDEN)

        participant.unread_count = 0
        participant.save(update_fields=['unread_count'])

        # Update existing message statuses to 'read'
        MessageStatus.objects.filter(
            message__conversation_id=conversation_id,
            user=request.user,
            status__in=['sent', 'delivered'],
        ).update(status='read', timestamp=timezone.now())

        # Create 'read' status for messages from others that don't have a status for this user
        for msg in Message.objects.filter(
            conversation_id=conversation_id
        ).exclude(sender=request.user):
            MessageStatus.objects.get_or_create(
                message=msg, user=request.user,
                defaults={'status': 'read'}
            )

        return Response({'status': 'ok', 'unread_count': 0})


class ConversationMuteView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            participant.muted_until = timezone.now() + timedelta(days=365)
            participant.save()
            return Response({'muted': True})
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)

    def delete(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            participant.muted_until = None
            participant.save()
            return Response({'muted': False})
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)


class ConversationClearView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            participant.cleared_at = timezone.now()
            participant.save()
            return Response({'cleared': True})
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)


class ConversationLeaveView(APIView):
    """Elimina la chat per l'utente corrente (nasconde il partecipante)."""
    permission_classes = [IsAuthenticated]

    def delete(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            participant.is_hidden = True
            participant.cleared_at = timezone.now()
            participant.save()
            return Response({'hidden': True}, status=status.HTTP_200_OK)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)


class ConversationDeleteForAllView(APIView):
    """Elimina la conversazione per tutti i partecipanti."""
    permission_classes = [IsAuthenticated]

    def delete(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            # Notifica tutti i partecipanti prima di eliminare
            channel_layer = get_channel_layer()
            room_group_name = f'conv_{conversation_id}'
            async_to_sync(channel_layer.group_send)(
                room_group_name,
                {
                    'type': 'conversation.deleted',
                    'conversation_id': str(conversation_id),
                    'deleted_by': request.user.id,
                }
            )
            # Elimina la conversazione
            participant.conversation.delete()
            return Response({'deleted': True}, status=status.HTTP_200_OK)
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)


class ConversationAvatarView(APIView):
    """Upload avatar per una conversazione di gruppo."""
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser]

    def post(self, request, conversation_id):
        try:
            conversation = Conversation.objects.get(id=conversation_id)
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata'}, status=status.HTTP_404_NOT_FOUND)

        if not ConversationParticipant.objects.filter(conversation=conversation, user=request.user).exists():
            return Response({'error': 'Non sei partecipante'}, status=status.HTTP_403_FORBIDDEN)

        avatar_file = request.FILES.get('avatar')
        if not avatar_file:
            return Response({'error': 'Nessun file fornito'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            group = conversation.group_info
        except Group.DoesNotExist:
            return Response({'error': 'Non è un gruppo'}, status=status.HTTP_400_BAD_REQUEST)

        group.avatar = avatar_file
        group.save()

        avatar_url = request.build_absolute_uri(group.avatar.url) if group.avatar else None
        return Response({'avatar': avatar_url}, status=status.HTTP_200_OK)


class MediaServeView(APIView):
    """Serve media files with range request support for iOS video streaming."""
    permission_classes = [IsAuthenticated]

    def get(self, request, file_path):
        # Prevent path traversal
        if '..' in file_path or file_path.startswith('/'):
            return Response({'error': 'File non trovato.'}, status=status.HTTP_404_NOT_FOUND)
        full_path = os.path.join(settings.MEDIA_ROOT, file_path)
        full_path = os.path.normpath(full_path)
        media_root = os.path.realpath(settings.MEDIA_ROOT)
        if not os.path.realpath(full_path).startswith(media_root):
            return Response({'error': 'File non trovato.'}, status=status.HTTP_404_NOT_FOUND)
        if not os.path.exists(full_path) or not os.path.isfile(full_path):
            return Response({'error': 'File non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        file_size = os.path.getsize(full_path)
        content_type = self._get_content_type(full_path)

        range_header = request.META.get('HTTP_RANGE', '')
        if range_header:
            range_match = re.match(r'bytes=(\d+)-(\d*)', range_header)
            if range_match:
                start = int(range_match.group(1))
                end = int(range_match.group(2)) if range_match.group(2) else file_size - 1
                end = min(end, file_size - 1)
                length = end - start + 1

                with open(full_path, 'rb') as f:
                    f.seek(start)
                    data = f.read(length)

                response = HttpResponse(data, status=206, content_type=content_type)
                response['Content-Length'] = str(length)
                response['Content-Range'] = f'bytes {start}-{end}/{file_size}'
                response['Accept-Ranges'] = 'bytes'
                return response

        response = FileResponse(open(full_path, 'rb'), content_type=content_type)
        response['Content-Length'] = str(file_size)
        response['Accept-Ranges'] = 'bytes'
        return response

    def _get_content_type(self, path):
        ext = os.path.splitext(path)[1].lower()
        types = {
            '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.avi': 'video/x-msvideo',
            '.ogg': 'video/ogg', '.ogv': 'video/ogg', '.webm': 'video/webm',
            '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.wave': 'audio/wav',
            '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
            '.gif': 'image/gif', '.webp': 'image/webp', '.pdf': 'application/pdf',
        }
        return types.get(ext, 'application/octet-stream')


class OfficeConvertView(APIView):
    """Converte file Office in PDF per visualizzazione in-app (LibreOffice headless)."""
    permission_classes = [IsAuthenticated]

    def get(self, request, attachment_id):
        try:
            attachment = Attachment.objects.get(id=attachment_id)
        except Attachment.DoesNotExist:
            return JsonResponse({'error': 'Not found'}, status=404)

        if not attachment.message_id:
            return JsonResponse({'error': 'Attachment not linked to message'}, status=400)

        message = attachment.message
        conversation = message.conversation
        is_participant = ConversationParticipant.objects.filter(
            conversation=conversation,
            user=request.user,
        ).exists()
        if not is_participant:
            return JsonResponse({'error': 'Forbidden'}, status=403)

        if not hasattr(attachment.file, 'path') or not attachment.file.path:
            return JsonResponse({'error': 'File not on disk'}, status=500)

        original_path = attachment.file.path
        if not os.path.exists(original_path):
            return JsonResponse({'error': 'File not found'}, status=404)

        pdf_path = original_path.rsplit('.', 1)[0] + '_converted.pdf'

        if not os.path.exists(pdf_path):
            try:
                output_dir = os.path.dirname(original_path)
                result = subprocess.run(
                    [
                        'libreoffice', '--headless', '--convert-to', 'pdf',
                        '--outdir', output_dir, original_path,
                    ],
                    capture_output=True,
                    timeout=30,
                )
                # LibreOffice genera file con stesso nome ma .pdf
                generated_pdf = original_path.rsplit('.', 1)[0] + '.pdf'
                if os.path.exists(generated_pdf) and generated_pdf != pdf_path:
                    os.rename(generated_pdf, pdf_path)
                if not os.path.exists(pdf_path):
                    return JsonResponse(
                        {'error': 'Conversion failed', 'stderr': (result.stderr or b'').decode('utf-8', errors='ignore')},
                        status=500,
                    )
            except subprocess.TimeoutExpired:
                return JsonResponse({'error': 'Conversion timeout'}, status=500)
            except Exception as e:
                return JsonResponse({'error': str(e)}, status=500)

        response = FileResponse(open(pdf_path, 'rb'), content_type='application/pdf')
        response['Content-Disposition'] = f'inline; filename="{os.path.basename(pdf_path)}"'
        return response


class AttachmentUploadView(APIView):
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser]

    ALLOWED_TYPES = {
        'image': ['image/jpeg', 'image/png', 'image/gif', 'image/webp'],
        'video': ['video/mp4', 'video/quicktime', 'video/webm', 'video/x-msvideo', 'video/ogg'],
        'audio': ['audio/mpeg', 'audio/ogg', 'audio/mp4', 'audio/webm', 'audio/wav', 'audio/wave'],
        'file': [],  # Accept any for documents
    }
    MAX_SIZES = {
        'image': 20 * 1024 * 1024,
        'video': 100 * 1024 * 1024,
        'audio': 20 * 1024 * 1024,
        'file': 50 * 1024 * 1024,
    }

    def post(self, request):
        """Upload an attachment for a message"""
        file = request.FILES.get('file')
        message_id = request.data.get('message_id')
        file_type = request.data.get('type', 'file')

        if not file:
            return Response({'error': 'Nessun file.'}, status=status.HTTP_400_BAD_REQUEST)

        # Size validation
        max_size = self.MAX_SIZES.get(file_type, 50 * 1024 * 1024)
        if file.size > max_size:
            return Response({'error': f'File troppo grande. Max {max_size // (1024*1024)}MB.'},
                          status=status.HTTP_400_BAD_REQUEST)

        # Type validation
        allowed = self.ALLOWED_TYPES.get(file_type, [])
        if allowed and file.content_type not in allowed:
            return Response({'error': 'Tipo file non supportato.'},
                          status=status.HTTP_400_BAD_REQUEST)

        try:
            message = Message.objects.get(id=message_id, sender=request.user)
        except Message.DoesNotExist:
            return Response({'error': 'Messaggio non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        # Create thumbnail for images/videos
        thumbnail = None
        width = height = None
        duration = None

        if file_type == 'image':
            try:
                from PIL import Image
                from io import BytesIO
                from django.core.files.uploadedfile import InMemoryUploadedFile
                import sys

                img = Image.open(file)
                width, height = img.size
                img.thumbnail((300, 300), Image.LANCZOS)
                thumb_io = BytesIO()
                img.save(thumb_io, format='JPEG', quality=70)
                thumb_io.seek(0)
                thumbnail = InMemoryUploadedFile(
                    thumb_io, 'thumbnail', f'thumb_{file.name}.jpg',
                    'image/jpeg', sys.getsizeof(thumb_io), None
                )
                file.seek(0)  # Reset file pointer
            except Exception:
                pass

        attachment = Attachment.objects.create(
            message=message,
            file=file,
            file_name=file.name,
            file_size=file.size,
            mime_type=file.content_type or 'application/octet-stream',
            thumbnail=thumbnail,
            width=width,
            height=height,
            duration=duration,
        )

        # Broadcast WebSocket: messaggio ora ha l'allegato, notifica i partecipanti
        try:
            message.refresh_from_db()
            message_data = MessageSerializer(message, context={'request': request}).data
            channel_layer = get_channel_layer()
            if channel_layer:
                conv_group = f'conv_{message.conversation_id}'
                async_to_sync(channel_layer.group_send)(conv_group, {
                    'type': 'chat.message',
                    'message': message_data,
                    'sender_id': request.user.id,
                })
        except Exception as e:
            import logging
            logging.getLogger(__name__).error(f'WS broadcast error (upload): {e}')

        serializer = AttachmentSerializer(attachment, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class LockPinView(APIView):
    """PIN di sblocco per chat con lucchetto (per-utente)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        """Imposta o cambia il PIN di sblocco."""
        from django.contrib.auth.hashers import make_password
        pin = request.data.get('pin', '')
        if len(str(pin)) < 6:
            return Response(
                {'error': 'PIN deve essere di almeno 6 cifre.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        request.user.lock_pin = make_password(str(pin))
        request.user.save(update_fields=['lock_pin'])
        return Response({'success': True})

    def put(self, request):
        """Verifica PIN esistente."""
        from django.contrib.auth.hashers import check_password
        pin = request.data.get('pin', '')
        if not request.user.lock_pin:
            return Response(
                {'valid': False, 'error': 'Nessun PIN impostato.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        valid = check_password(str(pin), request.user.lock_pin)
        return Response({'valid': valid})

    def get(self, request):
        """Controlla se l'utente ha già un PIN."""
        return Response({'has_pin': bool(request.user.lock_pin)})


class ConversationLockView(APIView):
    """Attiva/disattiva lucchetto su una chat (per-participant)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            participant.is_locked = not participant.is_locked
            participant.save(update_fields=['is_locked'])
            return Response({'is_locked': participant.is_locked})
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)


class ConversationFavoriteView(APIView):
    """Toggle favorite (preferiti) su una chat (per-participant)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        try:
            participant = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
            participant.is_favorite = not participant.is_favorite
            participant.save(update_fields=['is_favorite'])
            return Response({'is_favorite': participant.is_favorite})
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Not found'}, status=status.HTTP_404_NOT_FOUND)


class LockChatView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Lock a conversation with a PIN"""
        serializer = LockChatSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        pin = serializer.validated_data['pin']

        try:
            conversation = Conversation.objects.get(
                id=conversation_id, conversation_participants__user=request.user
            )
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        # Hash the PIN
        pin_hash = bcrypt.hashpw(pin.encode(), bcrypt.gensalt()).decode()
        conversation.is_locked = True
        conversation.lock_hash = pin_hash
        conversation.conv_type = 'secret'
        conversation.save(update_fields=['is_locked', 'lock_hash', 'conv_type'])

        return Response({'message': 'Chat bloccata con PIN.'})


class UnlockChatView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Unlock a locked conversation"""
        pin = request.data.get('pin', '')

        try:
            conversation = Conversation.objects.get(
                id=conversation_id, conversation_participants__user=request.user
            )
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversazione non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        if not conversation.is_locked:
            return Response({'message': 'Chat non bloccata.'})

        if bcrypt.checkpw(pin.encode(), conversation.lock_hash.encode()):
            return Response({'unlocked': True})
        else:
            return Response({'error': 'PIN errato.'}, status=status.HTTP_403_FORBIDDEN)


class LocationShareView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Share location in a conversation"""
        lat = request.data.get('latitude')
        lng = request.data.get('longitude')
        address = request.data.get('address', '')
        duration_minutes = request.data.get('duration_minutes', 0)

        if not lat or not lng:
            return Response({'error': 'Coordinate mancanti.'}, status=status.HTTP_400_BAD_REQUEST)

        msg_type = 'location_live' if duration_minutes > 0 else 'location'
        message = Message.objects.create(
            conversation_id=conversation_id,
            sender=request.user,
            message_type=msg_type,
        )

        live_until = None
        if duration_minutes > 0:
            live_until = timezone.now() + timedelta(minutes=duration_minutes)

        LocationShare.objects.create(
            message=message,
            latitude=lat,
            longitude=lng,
            address=address,
            is_live=duration_minutes > 0,
            live_until=live_until,
        )

        Conversation.objects.filter(id=conversation_id).update(
            last_message=message, updated_at=timezone.now()
        )

        serializer = MessageSerializer(message, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class CalendarEventView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Create and share a calendar event"""
        title = request.data.get('title')
        description = request.data.get('description', '')
        start = request.data.get('start_datetime')
        end = request.data.get('end_datetime')
        location = request.data.get('location', '')

        if not title or not start or not end:
            return Response({'error': 'Titolo e date obbligatori.'}, status=status.HTTP_400_BAD_REQUEST)

        message = Message.objects.create(
            conversation_id=conversation_id,
            sender=request.user,
            message_type='event',
        )

        event = CalendarEvent.objects.create(
            message=message,
            title=title,
            description=description,
            start_datetime=start,
            end_datetime=end,
            location=location,
        )

        # Generate .ics file
        try:
            from icalendar import Calendar, Event as ICalEvent
            from django.core.files.base import ContentFile

            cal = Calendar()
            cal.add('prodid', '-//SecureChat//EN')
            cal.add('version', '2.0')
            ical_event = ICalEvent()
            ical_event.add('summary', title)
            ical_event.add('description', description)
            ical_event.add('dtstart', event.start_datetime)
            ical_event.add('dtend', event.end_datetime)
            if location:
                ical_event.add('location', location)
            cal.add_component(ical_event)
            ics_content = cal.to_ical()
            event.ics_file.save(f'event_{event.id}.ics', ContentFile(ics_content))
        except Exception:
            pass

        Conversation.objects.filter(id=conversation_id).update(
            last_message=message, updated_at=timezone.now()
        )

        serializer = MessageSerializer(message, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class ReactionView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, message_id):
        """Add a reaction to a message"""
        emoji = request.data.get('emoji', '')
        if not emoji:
            return Response({'error': 'Emoji mancante.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            message = Message.objects.get(id=message_id)
        except Message.DoesNotExist:
            return Response({'error': 'Messaggio non trovato.'}, status=status.HTTP_404_NOT_FOUND)

        MessageReaction.objects.update_or_create(
            message=message, user=request.user,
            defaults={'emoji': emoji}
        )
        return Response({'message': 'Reazione aggiunta.'})

    def delete(self, request, message_id):
        """Remove a reaction"""
        MessageReaction.objects.filter(message_id=message_id, user=request.user).delete()
        return Response({'message': 'Reazione rimossa.'})


class LinkPreviewView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        """Generate a link preview from URL"""
        url = request.data.get('url', '')
        if not url:
            return Response({'error': 'URL mancante.'}, status=status.HTTP_400_BAD_REQUEST)

        from django.core.cache import cache
        cache_key = f'link_preview:{url}'
        cached = cache.get(cache_key)
        if cached:
            return Response(cached)

        try:
            import requests as http_requests
            from bs4 import BeautifulSoup

            headers = {'User-Agent': 'SecureChat/1.0 LinkPreview'}
            resp = http_requests.get(url, headers=headers, timeout=5, allow_redirects=True)
            soup = BeautifulSoup(resp.text, 'html.parser')

            preview = {
                'url': url,
                'title': '',
                'description': '',
                'image': '',
                'site_name': '',
            }

            # Open Graph tags
            for prop in ['title', 'description', 'image', 'site_name']:
                tag = soup.find('meta', property=f'og:{prop}')
                if tag and tag.get('content'):
                    preview[prop] = tag['content']

            # Fallbacks
            if not preview['title']:
                title_tag = soup.find('title')
                if title_tag:
                    preview['title'] = title_tag.string or ''

            if not preview['description']:
                desc_tag = soup.find('meta', attrs={'name': 'description'})
                if desc_tag and desc_tag.get('content'):
                    preview['description'] = desc_tag['content']

            cache.set(cache_key, preview, 86400)  # Cache 24 hours
            return Response(preview)

        except Exception as e:
            return Response({'error': 'Impossibile generare anteprima.'},
                          status=status.HTTP_400_BAD_REQUEST)


class SearchMessagesView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, conversation_id):
        """Search messages in a conversation"""
        query = request.query_params.get('q', '')
        if not query or len(query) < 2:
            return Response({'error': 'Query troppo corta (min 2 caratteri).'},
                          status=status.HTTP_400_BAD_REQUEST)

        if not ConversationParticipant.objects.filter(
            conversation_id=conversation_id, user=request.user
        ).exists():
            return Response({'error': 'Accesso negato.'}, status=status.HTTP_403_FORBIDDEN)

        # Search in content_for_translation (server-side searchable field)
        messages = Message.objects.filter(
            conversation_id=conversation_id,
            content_for_translation__icontains=query,
            is_deleted=False,
        ).select_related('sender').order_by('-created_at')[:50]

        serializer = MessageSerializer(messages, many=True, context={'request': request})
        return Response(serializer.data)


# ── STORIES ──

class StoryCreateView(APIView):
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request):
        """Create a new story"""
        story_type = request.data.get('story_type', 'text')
        media = request.FILES.get('media')
        text_content = request.data.get('text_content', '')
        background_color = request.data.get('background_color', '#000000')
        font_style = request.data.get('font_style', 'default')
        caption = request.data.get('caption', '')
        privacy = request.data.get('privacy', 'all')

        if story_type in ('image', 'video') and not media:
            return Response({'error': 'File media obbligatorio.'}, status=status.HTTP_400_BAD_REQUEST)

        story = Story.objects.create(
            user=request.user,
            story_type=story_type,
            media=media,
            text_content=text_content,
            background_color=background_color,
            font_style=font_style,
            caption=caption,
            privacy=privacy,
            expires_at=timezone.now() + timedelta(hours=24),
        )

        serializer = StorySerializer(story, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class StoryFeedView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """Get stories from contacts (not expired)"""
        stories = Story.objects.filter(
            is_active=True,
            expires_at__gt=timezone.now(),
        ).exclude(
            user=request.user
        ).select_related('user').prefetch_related('views').order_by('-created_at')

        # Filter by privacy
        visible = []
        for story in stories:
            if story.privacy == 'all':
                visible.append(story)
            elif story.privacy == 'custom':
                if story.allowed_users.filter(id=request.user.id).exists():
                    visible.append(story)
            elif story.privacy == 'except':
                if not story.excluded_users.filter(id=request.user.id).exists():
                    visible.append(story)

        serializer = StorySerializer(visible, many=True, context={'request': request})
        return Response(serializer.data)


class StoryViewRegisterView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, story_id):
        """Register a story view"""
        try:
            story = Story.objects.get(id=story_id, is_active=True)
        except Story.DoesNotExist:
            return Response({'error': 'Storia non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        StoryView.objects.get_or_create(story=story, viewer=request.user)
        return Response({'message': 'Visualizzazione registrata.'})


class StoryViewersView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, story_id):
        """Get who viewed a story (only story author)"""
        try:
            story = Story.objects.get(id=story_id, user=request.user)
        except Story.DoesNotExist:
            return Response({'error': 'Storia non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        viewers = StoryView.objects.filter(story=story).select_related('viewer').order_by('-viewed_at')
        from accounts.serializers import UserPublicSerializer
        data = [{
            'user': UserPublicSerializer(v.viewer).data,
            'viewed_at': v.viewed_at.isoformat(),
        } for v in viewers]

        return Response(data)


class StoryDeleteView(APIView):
    permission_classes = [IsAuthenticated]

    def delete(self, request, story_id):
        """Delete own story"""
        try:
            story = Story.objects.get(id=story_id, user=request.user)
        except Story.DoesNotExist:
            return Response({'error': 'Storia non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        if story.media:
            story.media.delete(save=False)
        story.delete()
        return Response({'message': 'Storia eliminata.'}, status=status.HTTP_200_OK)


# ── GROUPS ──

class CreateGroupView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        """Create a group conversation"""
        serializer = CreateGroupSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        name = serializer.validated_data['name']
        description = serializer.validated_data.get('description', '')
        member_ids = serializer.validated_data['member_ids']

        # Create conversation
        conversation = Conversation.objects.create(conv_type='group')

        # Add creator as admin
        ConversationParticipant.objects.create(
            conversation=conversation, user=request.user, role='admin'
        )

        # Add members
        from django.contrib.auth import get_user_model
        User = get_user_model()
        for uid in member_ids:
            if uid != request.user.id and User.objects.filter(id=uid, is_active=True).exists():
                ConversationParticipant.objects.create(
                    conversation=conversation, user_id=uid, role='member'
                )

        # Create group info
        invite_code = uuid.uuid4().hex[:12]
        Group.objects.create(
            conversation=conversation,
            name=name,
            description=description,
            created_by=request.user,
            invite_link=invite_code,
        )

        # System message
        Message.objects.create(
            conversation=conversation,
            sender=request.user,
            message_type='system',
            content_for_translation=f'{request.user.first_name} ha creato il gruppo "{name}"',
        )

        serializer = ConversationDetailSerializer(conversation, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


class GroupMembersView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, conversation_id):
        """Add a member to group (admin only)"""
        user_id = request.data.get('user_id')
        if not user_id:
            return Response({'error': 'user_id mancante.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            my_part = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user
            )
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Non sei nel gruppo.'}, status=status.HTTP_403_FORBIDDEN)

        group = Group.objects.filter(conversation_id=conversation_id).first()
        if group and group.only_admins_can_invite and my_part.role != 'admin':
            return Response({'error': 'Solo gli admin possono invitare.'}, status=status.HTTP_403_FORBIDDEN)

        # Check max members
        current_count = ConversationParticipant.objects.filter(conversation_id=conversation_id).count()
        if group and current_count >= group.max_members:
            return Response({'error': f'Limite membri raggiunto ({group.max_members}).'},
                          status=status.HTTP_400_BAD_REQUEST)

        participant, created = ConversationParticipant.objects.get_or_create(
            conversation_id=conversation_id, user_id=user_id,
            defaults={'role': 'member'}
        )

        if created:
            from django.contrib.auth import get_user_model
            User = get_user_model()
            new_user = User.objects.get(id=user_id)
            Message.objects.create(
                conversation_id=conversation_id,
                sender=request.user,
                message_type='system',
                content_for_translation=f'{new_user.first_name} è stato aggiunto al gruppo',
            )

        return Response({'message': 'Membro aggiunto.'}, status=status.HTTP_201_CREATED)

    def delete(self, request, conversation_id):
        """Remove a member from group (admin only)"""
        user_id = request.data.get('user_id')

        try:
            my_part = ConversationParticipant.objects.get(
                conversation_id=conversation_id, user=request.user, role='admin'
            )
        except ConversationParticipant.DoesNotExist:
            return Response({'error': 'Solo gli admin possono rimuovere.'}, status=status.HTTP_403_FORBIDDEN)

        if user_id == request.user.id:
            return Response({'error': 'Non puoi rimuovere te stesso.'}, status=status.HTTP_400_BAD_REQUEST)

        deleted, _ = ConversationParticipant.objects.filter(
            conversation_id=conversation_id, user_id=user_id
        ).delete()

        if deleted:
            from django.contrib.auth import get_user_model
            User = get_user_model()
            removed_user = User.objects.get(id=user_id)
            Message.objects.create(
                conversation_id=conversation_id,
                sender=request.user,
                message_type='system',
                content_for_translation=f'{removed_user.first_name} è stato rimosso dal gruppo',
            )

        return Response({'message': 'Membro rimosso.'})


class GroupJoinView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, invite_code):
        """Join a group via invite link"""
        try:
            group = Group.objects.get(invite_link=invite_code)
        except Group.DoesNotExist:
            return Response({'error': 'Link non valido.'}, status=status.HTTP_404_NOT_FOUND)

        if not group.is_invite_valid():
            return Response({'error': 'Link scaduto.'}, status=status.HTTP_400_BAD_REQUEST)

        current_count = ConversationParticipant.objects.filter(conversation=group.conversation).count()
        if current_count >= group.max_members:
            return Response({'error': 'Gruppo pieno.'}, status=status.HTTP_400_BAD_REQUEST)

        participant, created = ConversationParticipant.objects.get_or_create(
            conversation=group.conversation, user=request.user,
            defaults={'role': 'member'}
        )

        if created:
            Message.objects.create(
                conversation=group.conversation,
                sender=request.user,
                message_type='system',
                content_for_translation=f'{request.user.first_name} si è unito al gruppo',
            )

        serializer = ConversationDetailSerializer(group.conversation, context={'request': request})
        return Response(serializer.data)
