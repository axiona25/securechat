from rest_framework import generics, status, permissions
from rest_framework.response import Response
from rest_framework.views import APIView
from django.contrib.auth import get_user_model, authenticate, login
from django.utils import timezone
from django.db.models import Count, Q, Sum, Avg
from django.db.models.functions import TruncDate
from datetime import timedelta

from .permissions import IsAdminStaff, IsSuperAdmin
from .authentication import AdminJWTAuthentication, AdminSessionAuthentication
from .pagination import AdminPagination
from .serializers import (
    AdminLoginSerializer,
    AdminUserListSerializer, AdminUserDetailSerializer,
    AdminUserUpdateSerializer, AdminUserActionSerializer,
    AdminConversationListSerializer, AdminConversationDetailSerializer,
    AdminChannelListSerializer, AdminChannelActionSerializer,
    AdminCallListSerializer,
    AdminThreatListSerializer, AdminNetworkAnomalySerializer,
    AdminBroadcastNotificationSerializer,
    DashboardStatsSerializer, DailyStatSerializer,
    AdminChannelCategorySerializer,
)

User = get_user_model()

ADMIN_AUTH = [AdminJWTAuthentication, AdminSessionAuthentication]


# ────────────────────────── Auth ──────────────────────────

class AdminLoginView(APIView):
    """
    POST /api/admin-panel/auth/login/
    Login for admin panel. Returns JWT tokens + session cookie.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        serializer = AdminLoginSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        user = authenticate(
            request,
            username=serializer.validated_data['username'],
            password=serializer.validated_data['password'],
        )

        if user is None or not user.is_staff:
            return Response(
                {'error': 'Invalid credentials or not a staff user.'},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        login(request, user)

        from rest_framework_simplejwt.tokens import RefreshToken
        refresh = RefreshToken.for_user(user)

        return Response({
            'access': str(refresh.access_token),
            'refresh': str(refresh),
            'user': {
                'id': user.id,
                'username': user.username,
                'email': user.email,
                'is_superuser': user.is_superuser,
            },
        })


class AdminMeView(APIView):
    """
    GET /api/admin-panel/auth/me/
    Get current admin user info.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        user = request.user
        return Response({
            'id': user.id,
            'username': user.username,
            'email': user.email,
            'first_name': user.first_name,
            'last_name': user.last_name,
            'is_staff': user.is_staff,
            'is_superuser': user.is_superuser,
        })


# ────────────────────────── Dashboard ──────────────────────────

class DashboardStatsView(APIView):
    """
    GET /api/admin-panel/dashboard/stats/
    Overview counters for the admin dashboard.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        now = timezone.now()
        seven_days_ago = now - timedelta(days=7)

        total_users = User.objects.count()
        active_users_7d = User.objects.filter(last_seen__gte=seven_days_ago).count()
        online_users = User.objects.filter(is_online=True).count()

        try:
            from chat.models import Message
            total_messages = Message.objects.filter(is_deleted=False).count()
        except Exception:
            total_messages = 0

        try:
            from chat.models import Conversation
            total_conversations = Conversation.objects.count()
        except Exception:
            total_conversations = 0

        try:
            from channels_pub.models import Channel
            total_channels = Channel.objects.filter(is_active=True).count()
        except Exception:
            total_channels = 0

        try:
            from calls.models import Call
            total_calls = Call.objects.count()
        except Exception:
            total_calls = 0

        try:
            from security.models import ThreatDetection
            total_threats = ThreatDetection.objects.count()
            unresolved_threats = ThreatDetection.objects.exclude(status='resolved').count()
        except Exception:
            total_threats = 0
            unresolved_threats = 0

        return Response({
            'total_users': total_users,
            'active_users_7d': active_users_7d,
            'online_users': online_users,
            'total_messages': total_messages,
            'total_conversations': total_conversations,
            'total_channels': total_channels,
            'total_calls': total_calls,
            'total_threats': total_threats,
            'unresolved_threats': unresolved_threats,
        })


class DashboardChartsView(APIView):
    """
    GET /api/admin-panel/dashboard/charts/
    Daily data for charts (last 30 days): registrations, messages, calls.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        days = int(request.query_params.get('days', 30))
        days = min(days, 90)
        start_date = timezone.now() - timedelta(days=days)

        registrations = list(
            User.objects.filter(date_joined__gte=start_date)
            .annotate(date=TruncDate('date_joined'))
            .values('date')
            .annotate(count=Count('id'))
            .order_by('date')
        )

        try:
            from chat.models import Message
            messages_daily = list(
                Message.objects.filter(created_at__gte=start_date, is_deleted=False)
                .annotate(date=TruncDate('created_at'))
                .values('date')
                .annotate(count=Count('id'))
                .order_by('date')
            )
        except Exception:
            messages_daily = []

        try:
            from calls.models import Call
            calls_daily = list(
                Call.objects.filter(started_at__gte=start_date)
                .annotate(date=TruncDate('started_at'))
                .values('date')
                .annotate(count=Count('id'))
                .order_by('date')
            )
        except Exception:
            calls_daily = []

        return Response({
            'registrations': registrations,
            'messages': messages_daily,
            'calls': calls_daily,
            'days': days,
        })


class DashboardRecentThreatsView(APIView):
    """
    GET /api/admin-panel/dashboard/threats/
    Last 10 threat detections.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from security.models import ThreatDetection
            threats = ThreatDetection.objects.select_related('user').order_by('-detected_at')[:10]
            data = [
                {
                    'id': str(t.id),
                    'user_username': t.user.username if t.user else 'N/A',
                    'threat_type': getattr(t, 'detection_type', getattr(t, 'threat_type', '')),
                    'risk_level': str(t.severity) if hasattr(t, 'severity') else getattr(t, 'risk_level', ''),
                    'is_resolved': t.status == 'resolved',
                    'detected_at': t.detected_at,
                }
                for t in threats
            ]
        except Exception:
            data = []

        return Response(data)


# ────────────────────────── Users ──────────────────────────

class AdminUserListView(generics.ListAPIView):
    """
    GET /api/admin-panel/users/
    Paginated user list with search and filters.
    """
    serializer_class = AdminUserListSerializer
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]
    pagination_class = AdminPagination

    def get_queryset(self):
        qs = User.objects.all()

        search = self.request.query_params.get('search', '')
        if search:
            qs = qs.filter(
                Q(username__icontains=search) |
                Q(email__icontains=search) |
                Q(first_name__icontains=search) |
                Q(last_name__icontains=search) |
                Q(phone_number__icontains=search)
            )

        is_active = self.request.query_params.get('is_active')
        if is_active is not None:
            qs = qs.filter(is_active=is_active.lower() == 'true')

        is_verified = self.request.query_params.get('is_verified')
        if is_verified is not None:
            qs = qs.filter(is_verified=is_verified.lower() == 'true')

        is_staff = self.request.query_params.get('is_staff')
        if is_staff is not None:
            qs = qs.filter(is_staff=is_staff.lower() == 'true')

        date_from = self.request.query_params.get('date_from')
        if date_from:
            qs = qs.filter(date_joined__date__gte=date_from)

        date_to = self.request.query_params.get('date_to')
        if date_to:
            qs = qs.filter(date_joined__date__lte=date_to)

        ordering = self.request.query_params.get('ordering', '-date_joined')
        allowed_orderings = [
            'date_joined', '-date_joined', 'username', '-username',
            'email', '-email', 'last_seen', '-last_seen',
        ]
        if ordering in allowed_orderings:
            qs = qs.order_by(ordering)
        else:
            qs = qs.order_by('-date_joined')

        try:
            from chat.models import Message
            qs = qs.annotate(
                message_count=Count('sent_messages', filter=Q(sent_messages__is_deleted=False))
            )
        except Exception:
            pass

        try:
            from channels_pub.models import ChannelMember
            qs = qs.annotate(
                channel_count=Count('channel_memberships', filter=Q(channel_memberships__is_banned=False))
            )
        except Exception:
            pass

        return qs


class AdminUserDetailView(generics.RetrieveUpdateAPIView):
    """
    GET   /api/admin-panel/users/<id>/
    PATCH /api/admin-panel/users/<id>/
    """
    queryset = User.objects.all()
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]
    lookup_field = 'id'

    def get_serializer_class(self):
        if self.request.method in ('PATCH', 'PUT'):
            return AdminUserUpdateSerializer
        return AdminUserDetailSerializer


class AdminUserActionView(APIView):
    """
    POST /api/admin-panel/users/<id>/action/
    Perform actions: activate, deactivate, verify, make_staff, force_logout, etc.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def post(self, request, id):
        try:
            user = User.objects.get(id=id)
        except User.DoesNotExist:
            return Response({'error': 'User not found.'}, status=status.HTTP_404_NOT_FOUND)

        serializer = AdminUserActionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        action = serializer.validated_data['action']

        if user.id == request.user.id and action in ('deactivate', 'remove_staff', 'remove_superuser'):
            return Response({'error': 'Cannot perform this action on yourself.'}, status=status.HTTP_400_BAD_REQUEST)

        if action in ('make_superuser', 'remove_superuser') and not request.user.is_superuser:
            return Response({'error': 'Only superusers can manage superuser status.'}, status=status.HTTP_403_FORBIDDEN)

        actions_map = {
            'activate': lambda: setattr(user, 'is_active', True),
            'deactivate': lambda: setattr(user, 'is_active', False),
            'verify': lambda: setattr(user, 'is_verified', True),
            'unverify': lambda: setattr(user, 'is_verified', False),
            'make_staff': lambda: setattr(user, 'is_staff', True),
            'remove_staff': lambda: setattr(user, 'is_staff', False),
            'make_superuser': lambda: [setattr(user, 'is_superuser', True), setattr(user, 'is_staff', True)],
            'remove_superuser': lambda: setattr(user, 'is_superuser', False),
        }

        if action == 'force_logout':
            return self._force_logout(user)

        if action in actions_map:
            actions_map[action]()
            user.save()
            return Response({'detail': f'Action "{action}" applied to {user.username}.'})

        return Response({'error': 'Unknown action.'}, status=status.HTTP_400_BAD_REQUEST)

    def _force_logout(self, user):
        try:
            from rest_framework_simplejwt.token_blacklist.models import OutstandingToken, BlacklistedToken
            tokens = OutstandingToken.objects.filter(user=user)
            for token in tokens:
                BlacklistedToken.objects.get_or_create(token=token)
        except Exception:
            pass

        try:
            from notifications.models import DeviceToken
            DeviceToken.objects.filter(user=user).update(is_active=False)
        except Exception:
            pass

        if hasattr(user, 'firebase_token') and user.firebase_token:
            user.firebase_token = ''
            user.save(update_fields=['firebase_token'])

        return Response({'detail': f'User {user.username} force-logged out.'})


# ────────────────────────── Conversations ──────────────────────────

class AdminConversationListView(APIView):
    """
    GET /api/admin-panel/conversations/
    Paginated list of conversations.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from chat.models import Conversation, Message

            qs = Conversation.objects.annotate(
                participant_count=Count('conversation_participants'),
                message_count=Count('messages', filter=Q(messages__is_deleted=False)),
            ).order_by('-created_at')

            conv_type = request.query_params.get('conv_type')
            if conv_type:
                qs = qs.filter(conv_type=conv_type)

            search = request.query_params.get('search', '')
            if search:
                qs = qs.filter(
                    Q(conversation_participants__user__username__icontains=search)
                ).distinct()

            paginator = AdminPagination()
            page = paginator.paginate_queryset(qs, request)

            data = []
            for conv in page:
                last_msg = Message.objects.filter(
                    conversation=conv, is_deleted=False
                ).order_by('-created_at').values('created_at').first()

                data.append({
                    'id': str(conv.id),
                    'conv_type': conv.conv_type,
                    'name': getattr(conv, 'name', None),
                    'participant_count': conv.participant_count,
                    'message_count': conv.message_count,
                    'last_message_at': last_msg['created_at'] if last_msg else None,
                    'created_at': conv.created_at,
                })

            return paginator.get_paginated_response(data)

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminConversationDetailView(APIView):
    """
    GET /api/admin-panel/conversations/<id>/
    Conversation detail with participants and recent messages.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request, id):
        from chat.models import Conversation, ConversationParticipant, Message
        try:
            conv = Conversation.objects.get(id=id)

            participants = list(
                ConversationParticipant.objects.filter(conversation=conv)
                .select_related('user')
                .values(
                    'user__id', 'user__username', 'role', 'joined_at'
                )
            )

            recent_qs = Message.objects.filter(conversation=conv, is_deleted=False).select_related('sender').order_by('-created_at')[:50]
            recent_messages = []
            for msg in recent_qs:
                content = getattr(msg, 'content_for_translation', '') or ''
                if not content and getattr(msg, 'content_encrypted', None):
                    content = '[encrypted]'
                recent_messages.append({
                    'id': str(msg.id),
                    'sender__username': msg.sender.username if msg.sender else 'N/A',
                    'content': content,
                    'message_type': msg.message_type,
                    'created_at': msg.created_at,
                })

            message_count = Message.objects.filter(conversation=conv, is_deleted=False).count()

            return Response({
                'id': str(conv.id),
                'conv_type': conv.conv_type,
                'name': getattr(conv, 'name', None),
                'created_at': conv.created_at,
                'participants': participants,
                'recent_messages': recent_messages,
                'message_count': message_count,
            })

        except Conversation.DoesNotExist:
            return Response({'error': 'Conversation not found.'}, status=status.HTTP_404_NOT_FOUND)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminConversationDeleteView(APIView):
    """
    DELETE /api/admin-panel/conversations/<id>/delete/
    Soft-delete a conversation (mark all messages as deleted).
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsSuperAdmin]

    def delete(self, request, id):
        from chat.models import Conversation, Message
        try:
            conv = Conversation.objects.get(id=id)
            Message.objects.filter(conversation=conv).update(is_deleted=True)
            return Response({'detail': f'All messages in conversation {id} marked as deleted.'})
        except Conversation.DoesNotExist:
            return Response({'error': 'Conversation not found.'}, status=status.HTTP_404_NOT_FOUND)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── Channels ──────────────────────────

class AdminChannelListView(APIView):
    """
    GET /api/admin-panel/channels/
    Paginated channel list.
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from channels_pub.models import Channel, ChannelPost

            qs = Channel.objects.select_related('owner').annotate(
                post_count=Count('posts', filter=Q(posts__is_published=True))
            ).order_by('-created_at')

            channel_type = request.query_params.get('channel_type')
            if channel_type:
                qs = qs.filter(channel_type=channel_type)

            is_active = request.query_params.get('is_active')
            if is_active is not None:
                qs = qs.filter(is_active=is_active.lower() == 'true')

            is_verified = request.query_params.get('is_verified')
            if is_verified is not None:
                qs = qs.filter(is_verified=is_verified.lower() == 'true')

            search = request.query_params.get('search', '')
            if search:
                qs = qs.filter(
                    Q(name__icontains=search) |
                    Q(username__icontains=search)
                )

            paginator = AdminPagination()
            page = paginator.paginate_queryset(qs, request)

            data = [
                {
                    'id': str(ch.id),
                    'name': ch.name,
                    'username': ch.username,
                    'channel_type': ch.channel_type,
                    'owner_username': ch.owner.username if ch.owner else 'N/A',
                    'subscriber_count': ch.subscriber_count,
                    'post_count': getattr(ch, 'post_count', 0),
                    'is_active': ch.is_active,
                    'is_verified': ch.is_verified,
                    'created_at': ch.created_at,
                }
                for ch in page
            ]

            return paginator.get_paginated_response(data)

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminChannelActionView(APIView):
    """
    POST /api/admin-panel/channels/<id>/action/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def post(self, request, id):
        from channels_pub.models import Channel
        try:
            channel = Channel.objects.get(id=id)
        except Channel.DoesNotExist:
            return Response({'error': 'Channel not found.'}, status=status.HTTP_404_NOT_FOUND)
        except Exception:
            return Response({'error': 'Channel module not available.'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        serializer = AdminChannelActionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        action = serializer.validated_data['action']

        if action == 'verify':
            channel.is_verified = True
        elif action == 'unverify':
            channel.is_verified = False
        elif action == 'activate':
            channel.is_active = True
        elif action == 'deactivate':
            channel.is_active = False

        channel.save()
        return Response({'detail': f'Action "{action}" applied to @{channel.username}.'})


class AdminChannelDeleteView(APIView):
    """
    DELETE /api/admin-panel/channels/<id>/delete/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsSuperAdmin]

    def delete(self, request, id):
        try:
            from channels_pub.models import Channel
            channel = Channel.objects.get(id=id)
            channel.is_active = False
            channel.save(update_fields=['is_active'])
            return Response({'detail': f'Channel @{channel.username} deactivated.'})
        except Exception as e:
            from django.core.exceptions import ObjectDoesNotExist
            if isinstance(e, ObjectDoesNotExist):
                return Response({'error': 'Channel not found.'}, status=status.HTTP_404_NOT_FOUND)
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── Channel Categories ──────────────────────────

class AdminChannelCategoryListCreateView(APIView):
    """
    GET  /api/admin-panel/channel-categories/
    POST /api/admin-panel/channel-categories/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from channels_pub.models import ChannelCategory
            categories = ChannelCategory.objects.all().order_by('order')
            data = [
                {
                    'id': cat.id,
                    'name': cat.name,
                    'slug': cat.slug,
                    'icon': getattr(cat, 'icon', ''),
                    'order': cat.order,
                }
                for cat in categories
            ]
            return Response(data)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    def post(self, request):
        try:
            from channels_pub.models import ChannelCategory
            serializer = AdminChannelCategorySerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            data = serializer.validated_data
            cat = ChannelCategory.objects.create(
                name=data['name'],
                slug=data['slug'],
                icon=data.get('icon', ''),
                order=data.get('order', 0),
            )
            return Response({
                'id': cat.id,
                'name': cat.name,
                'slug': cat.slug,
                'icon': cat.icon,
                'order': cat.order,
            }, status=status.HTTP_201_CREATED)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_400_BAD_REQUEST)


class AdminChannelCategoryDetailView(APIView):
    """
    PATCH  /api/admin-panel/channel-categories/<id>/
    DELETE /api/admin-panel/channel-categories/<id>/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def patch(self, request, id):
        from channels_pub.models import ChannelCategory
        try:
            cat = ChannelCategory.objects.get(id=id)
            for field in ('name', 'slug', 'icon', 'order'):
                if field in request.data:
                    setattr(cat, field, request.data[field])
            cat.save()
            return Response({
                'id': cat.id, 'name': cat.name, 'slug': cat.slug,
                'icon': getattr(cat, 'icon', ''), 'order': cat.order,
            })
        except ChannelCategory.DoesNotExist:
            return Response({'error': 'Category not found.'}, status=status.HTTP_404_NOT_FOUND)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_400_BAD_REQUEST)

    def delete(self, request, id):
        from channels_pub.models import ChannelCategory
        try:
            cat = ChannelCategory.objects.get(id=id)
            cat.delete()
            return Response({'detail': 'Category deleted.'})
        except ChannelCategory.DoesNotExist:
            return Response({'error': 'Category not found.'}, status=status.HTTP_404_NOT_FOUND)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── Calls ──────────────────────────

class AdminCallListView(APIView):
    """
    GET /api/admin-panel/calls/
    Paginated call list. Call model uses initiated_by (not caller).
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from calls.models import Call

            qs = Call.objects.select_related('initiated_by').annotate(
                participant_count=Count('participants')
            ).order_by('-started_at', '-created_at')

            call_type = request.query_params.get('call_type')
            if call_type:
                qs = qs.filter(call_type=call_type)

            call_status = request.query_params.get('status')
            if call_status:
                qs = qs.filter(status=call_status)

            date_from = request.query_params.get('date_from')
            if date_from:
                qs = qs.filter(started_at__date__gte=date_from)

            date_to = request.query_params.get('date_to')
            if date_to:
                qs = qs.filter(started_at__date__lte=date_to)

            paginator = AdminPagination()
            page = paginator.paginate_queryset(qs, request)

            data = [
                {
                    'id': str(c.id),
                    'caller_username': c.initiated_by.username if c.initiated_by else 'N/A',
                    'call_type': c.call_type,
                    'status': c.status,
                    'started_at': c.started_at,
                    'ended_at': c.ended_at,
                    'duration': c.duration,
                    'participant_count': getattr(c, 'participant_count', 0),
                }
                for c in page
            ]

            return paginator.get_paginated_response(data)

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminCallStatsView(APIView):
    """
    GET /api/admin-panel/calls/stats/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from calls.models import Call

            total = Call.objects.count()
            avg_duration = Call.objects.filter(
                duration__isnull=False
            ).exclude(duration=0).aggregate(avg=Avg('duration'))['avg'] or 0

            by_type = list(
                Call.objects.values('call_type')
                .annotate(count=Count('id'))
                .order_by('-count')
            )

            by_status = list(
                Call.objects.values('status')
                .annotate(count=Count('id'))
                .order_by('-count')
            )

            return Response({
                'total_calls': total,
                'avg_duration_seconds': round(avg_duration, 1),
                'by_type': by_type,
                'by_status': by_status,
            })

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── Security ──────────────────────────

class AdminThreatListView(APIView):
    """
    GET /api/admin-panel/security/threats/
    ThreatDetection uses detection_type, severity (int), status (resolved).
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from security.models import ThreatDetection

            qs = ThreatDetection.objects.select_related('user').order_by('-detected_at')

            risk_level = request.query_params.get('risk_level')
            if risk_level:
                try:
                    qs = qs.filter(severity=int(risk_level))
                except ValueError:
                    pass

            is_resolved = request.query_params.get('is_resolved')
            if is_resolved is not None:
                if is_resolved.lower() == 'true':
                    qs = qs.filter(status='resolved')
                else:
                    qs = qs.exclude(status='resolved')

            threat_type = request.query_params.get('threat_type')
            if threat_type:
                qs = qs.filter(detection_type=threat_type)

            paginator = AdminPagination()
            page = paginator.paginate_queryset(qs, request)

            data = [
                {
                    'id': str(t.id),
                    'user_username': t.user.username if t.user else 'N/A',
                    'threat_type': t.detection_type,
                    'risk_level': str(t.severity),
                    'is_resolved': t.status == 'resolved',
                    'detected_at': t.detected_at,
                    'resolved_at': getattr(t, 'resolved_at', None),
                }
                for t in page
            ]

            return paginator.get_paginated_response(data)

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminThreatResolveView(APIView):
    """
    POST /api/admin-panel/security/threats/<id>/resolve/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def post(self, request, id):
        from security.models import ThreatDetection
        try:
            threat = ThreatDetection.objects.get(id=id)
            threat.status = 'resolved'
            threat.resolved_at = timezone.now()
            threat.save(update_fields=['status', 'resolved_at'])
            return Response({'detail': 'Threat marked as resolved.'})
        except ThreatDetection.DoesNotExist:
            return Response({'error': 'Threat not found.'}, status=status.HTTP_404_NOT_FOUND)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminThreatStatsView(APIView):
    """
    GET /api/admin-panel/security/stats/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from security.models import ThreatDetection
            from django.db.models import Q
            by_level = list(
                ThreatDetection.objects.values('severity')
                .annotate(
                    total=Count('id'),
                    unresolved=Count('id', filter=~Q(status='resolved')),
                )
                .order_by('severity')
            )
            by_level = [{'risk_level': str(x['severity']), 'total': x['total'], 'unresolved': x['unresolved']} for x in by_level]

            by_type = list(
                ThreatDetection.objects.values('detection_type')
                .annotate(count=Count('id'))
                .order_by('-count')[:10]
            )
            by_type = [{'threat_type': x['detection_type'], 'count': x['count']} for x in by_type]

            return Response({
                'by_risk_level': by_level,
                'by_threat_type': by_type,
            })

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class AdminNetworkAnomalyListView(APIView):
    """
    GET /api/admin-panel/security/anomalies/
    NetworkAnomalyLog has destination_ip, is_suspicious, suspicion_reason (no source_ip/anomaly_type/severity string).
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from security.models import NetworkAnomalyLog

            qs = NetworkAnomalyLog.objects.select_related('user').order_by('-detected_at')

            severity = request.query_params.get('severity')
            if severity:
                if severity.lower() == 'high':
                    qs = qs.filter(is_suspicious=True)
                elif severity.lower() == 'low':
                    qs = qs.filter(is_suspicious=False)

            paginator = AdminPagination()
            page = paginator.paginate_queryset(qs, request)

            data = []
            for a in page:
                data.append({
                    'id': str(a.id),
                    'user_username': a.user.username if a.user else 'N/A',
                    'anomaly_type': (a.suspicion_reason or 'network')[:100],
                    'severity': 'high' if a.is_suspicious else 'low',
                    'source_ip': str(a.destination_ip) if a.destination_ip else '',
                    'detected_at': a.detected_at,
                })

            return paginator.get_paginated_response(data)

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── Broadcast Notification ──────────────────────────

class AdminBroadcastNotificationView(APIView):
    """
    POST /api/admin-panel/notifications/broadcast/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsSuperAdmin]

    def post(self, request):
        serializer = AdminBroadcastNotificationSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        target_map = {
            'all': Q(),
            'active': Q(is_active=True),
            'staff': Q(is_staff=True),
            'verified': Q(is_verified=True),
        }

        q_filter = target_map.get(data['target'], Q())
        user_ids = list(
            User.objects.filter(q_filter).values_list('id', flat=True)
        )

        if not user_ids:
            return Response({'detail': 'No users match the target.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            from notifications.services import NotificationService
            from notifications.models import NotificationType
            NotificationService.send_to_multiple(
                recipient_ids=user_ids,
                notification_type=NotificationType.SECURITY_ALERT,
                title=data['title'],
                body=data['body'],
                sender_id=request.user.id,
                source_type='admin_broadcast',
                high_priority=False,
            )
        except Exception as e:
            return Response({'error': f'Failed to send: {e}'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        return Response({
            'detail': f'Notification sent to {len(user_ids)} users.',
            'target': data['target'],
            'recipient_count': len(user_ids),
        })


class AdminNotificationStatsView(APIView):
    """
    GET /api/admin-panel/notifications/stats/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from notifications.models import Notification

            total = Notification.objects.count()
            sent = Notification.objects.filter(fcm_sent=True).count()
            read = Notification.objects.filter(is_read=True).count()
            read_rate = round((read / total * 100), 1) if total > 0 else 0.0

            by_type = list(
                Notification.objects.values('notification_type')
                .annotate(
                    total=Count('id'),
                    read=Count('id', filter=Q(is_read=True)),
                    sent=Count('id', filter=Q(fcm_sent=True)),
                )
                .order_by('-total')
            )

            return Response({
                'total_notifications': total,
                'total_sent': sent,
                'total_read': read,
                'read_rate': read_rate,
                'by_type': by_type,
            })

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── Translation Stats ──────────────────────────

class AdminTranslationStatsView(APIView):
    """
    GET /api/admin-panel/translations/stats/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        try:
            from translation.models import TranslationUsageLog, InstalledLanguagePack

            logs = TranslationUsageLog.objects.all()
            total = logs.count()
            total_chars = logs.aggregate(total=Sum('char_count'))['total'] or 0
            cached = logs.filter(cached=True).count()
            cache_hit_rate = round((cached / total * 100), 1) if total > 0 else 0.0

            top_pairs = list(
                logs.values('source_language', 'target_language')
                .annotate(count=Count('id'), chars=Sum('char_count'))
                .order_by('-count')[:10]
            )

            packs = list(
                InstalledLanguagePack.objects.all()
                .values(
                    'source_language', 'source_language_name',
                    'target_language', 'target_language_name',
                    'installed_at',
                )
            )

            return Response({
                'total_translations': total,
                'total_chars': total_chars,
                'cached_translations': cached,
                'cache_hit_rate': cache_hit_rate,
                'top_pairs': top_pairs,
                'installed_packs': packs,
            })

        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


# ────────────────────────── System Info ──────────────────────────

class AdminSystemInfoView(APIView):
    """
    GET /api/admin-panel/system/info/
    """
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminStaff]

    def get(self, request):
        import django
        import sys

        info = {
            'django_version': django.__version__,
            'python_version': sys.version,
            'server_time': timezone.now().isoformat(),
        }

        try:
            from django.core.cache import cache
            cache.set('admin_health_check', 'ok', 10)
            redis_ok = cache.get('admin_health_check') == 'ok'
            info['redis'] = 'connected' if redis_ok else 'error'
        except Exception:
            info['redis'] = 'disconnected'

        try:
            from celery import current_app
            inspector = current_app.control.inspect(timeout=2.0)
            active = inspector.active()
            info['celery'] = 'connected' if active else 'no workers'
            info['celery_workers'] = len(active) if active else 0
        except Exception:
            info['celery'] = 'disconnected'
            info['celery_workers'] = 0

        info['db_tables'] = {
            'users': User.objects.count(),
        }
        try:
            from chat.models import Message
            info['db_tables']['messages'] = Message.objects.count()
        except Exception:
            pass
        try:
            from channels_pub.models import Channel
            info['db_tables']['channels'] = Channel.objects.filter(is_active=True).count()
        except Exception:
            pass

        try:
            from django.conf import settings
            info['firebase_enabled'] = getattr(settings, 'FIREBASE_ENABLED', False)
        except Exception:
            info['firebase_enabled'] = False

        return Response(info)
