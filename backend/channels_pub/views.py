from rest_framework import generics, status, permissions, filters
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.parsers import MultiPartParser, FormParser, JSONParser
from rest_framework.exceptions import PermissionDenied
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.db.models import Count, Sum, Q, F, Case, When, IntegerField
from datetime import timedelta

from .models import (
    ChannelCategory, Channel, ChannelMember, ChannelPost,
    PostReaction, PostComment, PostView, Poll, PollOption, PollVote,
)
from .serializers import (
    ChannelCategorySerializer, ChannelListSerializer, ChannelCreateSerializer,
    ChannelDetailSerializer, ChannelUpdateSerializer, ChannelMemberSerializer,
    ChannelPostListSerializer, ChannelPostCreateSerializer,
    PostReactionSerializer, PostCommentSerializer, PollSerializer,
    ChannelStatsSerializer,
)
from .permissions import IsChannelOwner, IsChannelAdmin, IsChannelMember


# ────────────────────────── Categories ──────────────────────────

class ChannelCategoryListView(generics.ListAPIView):
    """GET /api/channels/categories/ — list all categories."""
    queryset = ChannelCategory.objects.all()
    serializer_class = ChannelCategorySerializer
    permission_classes = [permissions.AllowAny]
    pagination_class = None


# ────────────────────────── Channel CRUD ──────────────────────────

class ChannelListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/channels/           — list public channels (search/filter)
    POST /api/channels/           — create a channel
    """
    permission_classes = [permissions.IsAuthenticated]
    filter_backends = [filters.SearchFilter, filters.OrderingFilter]
    search_fields = ['name', 'username', 'description']
    ordering_fields = ['subscriber_count', 'created_at', 'name']
    ordering = ['-subscriber_count']

    def get_queryset(self):
        qs = Channel.objects.filter(is_active=True)
        category = self.request.query_params.get('category')
        channel_type = self.request.query_params.get('type')
        if category:
            qs = qs.filter(category__slug=category)
        if channel_type:
            qs = qs.filter(channel_type=channel_type)
        # Non-members can only see public channels
        if self.request.method == 'GET':
            qs = qs.filter(
                Q(channel_type=Channel.ChannelType.PUBLIC) |
                Q(members__user=self.request.user, members__is_banned=False)
            ).distinct()
        return qs

    def get_serializer_class(self):
        if self.request.method == 'POST':
            return ChannelCreateSerializer
        return ChannelListSerializer

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx


class ChannelDetailView(generics.RetrieveUpdateDestroyAPIView):
    """
    GET    /api/channels/<id>/    — channel detail
    PATCH  /api/channels/<id>/    — update channel (owner/admin)
    DELETE /api/channels/<id>/    — delete channel (owner only)
    """
    queryset = Channel.objects.filter(is_active=True)
    lookup_field = 'id'
    permission_classes = [permissions.IsAuthenticated]

    def get_serializer_class(self):
        if self.request.method in ('PATCH', 'PUT'):
            return ChannelUpdateSerializer
        return ChannelDetailSerializer

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx

    def check_object_permissions(self, request, obj):
        super().check_object_permissions(request, obj)
        if request.method in ('PATCH', 'PUT'):
            perm = IsChannelAdmin()
            if not perm.has_object_permission(request, self, obj):
                self.permission_denied(request, message='Only owner or admin can edit this channel.')
        elif request.method == 'DELETE':
            perm = IsChannelOwner()
            if not perm.has_object_permission(request, self, obj):
                self.permission_denied(request, message='Only the owner can delete this channel.')

    def perform_destroy(self, instance):
        instance.is_active = False
        instance.save(update_fields=['is_active'])


# ────────────────────────── Subscribe / Unsubscribe ──────────────────────────

class ChannelSubscribeView(APIView):
    """POST /api/channels/<id>/subscribe/ — subscribe to channel."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        if ChannelMember.objects.filter(channel=channel, user=request.user, is_banned=True).exists():
            return Response({'error': 'You are banned from this channel.'}, status=status.HTTP_403_FORBIDDEN)
        membership, created = ChannelMember.objects.get_or_create(
            channel=channel,
            user=request.user,
            defaults={'role': ChannelMember.Role.SUBSCRIBER}
        )
        if not created:
            return Response({'detail': 'Already subscribed.'}, status=status.HTTP_200_OK)
        Channel.objects.filter(id=channel.id).update(subscriber_count=F('subscriber_count') + 1)
        return Response({'detail': 'Subscribed successfully.'}, status=status.HTTP_201_CREATED)


class ChannelUnsubscribeView(APIView):
    """POST /api/channels/<id>/unsubscribe/ — unsubscribe from channel."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        membership = ChannelMember.objects.filter(
            channel=channel, user=request.user
        ).first()
        if not membership:
            return Response({'detail': 'Not subscribed.'}, status=status.HTTP_400_BAD_REQUEST)
        if membership.role == ChannelMember.Role.OWNER:
            return Response(
                {'error': 'Owner cannot unsubscribe. Transfer ownership first.'},
                status=status.HTTP_400_BAD_REQUEST
            )
        membership.delete()
        Channel.objects.filter(id=channel.id, subscriber_count__gt=0).update(
            subscriber_count=F('subscriber_count') - 1
        )
        return Response({'detail': 'Unsubscribed.'}, status=status.HTTP_200_OK)


# ────────────────────────── Join by Invite Code ──────────────────────────

class ChannelJoinByInviteView(APIView):
    """POST /api/channels/join/<invite_code>/ — join via invite link."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, invite_code):
        channel = get_object_or_404(Channel, invite_code=invite_code, is_active=True)
        if ChannelMember.objects.filter(channel=channel, user=request.user, is_banned=True).exists():
            return Response({'error': 'You are banned from this channel.'}, status=status.HTTP_403_FORBIDDEN)
        membership, created = ChannelMember.objects.get_or_create(
            channel=channel,
            user=request.user,
            defaults={'role': ChannelMember.Role.SUBSCRIBER}
        )
        if not created:
            return Response({'detail': 'Already a member.'}, status=status.HTTP_200_OK)
        Channel.objects.filter(id=channel.id).update(subscriber_count=F('subscriber_count') + 1)
        serializer = ChannelDetailSerializer(channel, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED)


# ────────────────────────── Regenerate Invite Code ──────────────────────────

class ChannelRegenerateInviteView(APIView):
    """POST /api/channels/<id>/regenerate-invite/ — owner/admin only."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        perm = IsChannelAdmin()
        if not perm.has_object_permission(request, self, channel):
            return Response({'error': 'Permission denied.'}, status=status.HTTP_403_FORBIDDEN)
        new_code = channel.regenerate_invite_code()
        return Response({'invite_code': new_code, 'invite_link': f'/c/{new_code}'})


# ────────────────────────── Members Management ──────────────────────────

class ChannelMembersView(generics.ListAPIView):
    """GET /api/channels/<id>/members/ — list members."""
    serializer_class = ChannelMemberSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        channel_id = self.kwargs['id']
        return ChannelMember.objects.filter(
            channel_id=channel_id, is_banned=False
        ).select_related('user').order_by(
            Case(
                When(role=ChannelMember.Role.OWNER, then=0),
                When(role=ChannelMember.Role.ADMIN, then=1),
                default=2,
                output_field=IntegerField(),
            ),
            'joined_at'
        )


class ChannelPromoteAdminView(APIView):
    """POST /api/channels/<id>/promote/ — owner promotes user to admin."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        if channel.owner_id != request.user.id:
            return Response({'error': 'Only the owner can promote admins.'}, status=status.HTTP_403_FORBIDDEN)
        user_id = request.data.get('user_id')
        if not user_id:
            return Response({'error': 'user_id is required.'}, status=status.HTTP_400_BAD_REQUEST)
        membership = ChannelMember.objects.filter(
            channel=channel, user_id=user_id, is_banned=False
        ).first()
        if not membership:
            return Response({'error': 'User is not a member.'}, status=status.HTTP_404_NOT_FOUND)
        if membership.role == ChannelMember.Role.OWNER:
            return Response({'error': 'Cannot change owner role.'}, status=status.HTTP_400_BAD_REQUEST)
        membership.role = ChannelMember.Role.ADMIN
        membership.save(update_fields=['role'])
        return Response({'detail': f'{membership.user.username} is now admin.'})


class ChannelDemoteAdminView(APIView):
    """POST /api/channels/<id>/demote/ — owner demotes admin to subscriber."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        if channel.owner_id != request.user.id:
            return Response({'error': 'Only the owner can demote admins.'}, status=status.HTTP_403_FORBIDDEN)
        user_id = request.data.get('user_id')
        if not user_id:
            return Response({'error': 'user_id is required.'}, status=status.HTTP_400_BAD_REQUEST)
        membership = ChannelMember.objects.filter(
            channel=channel, user_id=user_id, is_banned=False
        ).first()
        if not membership:
            return Response({'error': 'User is not a member.'}, status=status.HTTP_404_NOT_FOUND)
        if membership.role != ChannelMember.Role.ADMIN:
            return Response({'error': 'User is not an admin.'}, status=status.HTTP_400_BAD_REQUEST)
        membership.role = ChannelMember.Role.SUBSCRIBER
        membership.save(update_fields=['role'])
        return Response({'detail': f'{membership.user.username} demoted to subscriber.'})


class ChannelBanUserView(APIView):
    """POST /api/channels/<id>/ban/ — admin/owner bans a user."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        perm = IsChannelAdmin()
        if not perm.has_object_permission(request, self, channel):
            return Response({'error': 'Permission denied.'}, status=status.HTTP_403_FORBIDDEN)
        user_id = request.data.get('user_id')
        if not user_id:
            return Response({'error': 'user_id is required.'}, status=status.HTTP_400_BAD_REQUEST)
        membership = ChannelMember.objects.filter(channel=channel, user_id=user_id).first()
        if not membership:
            return Response({'error': 'User is not a member.'}, status=status.HTTP_404_NOT_FOUND)
        if membership.role == ChannelMember.Role.OWNER:
            return Response({'error': 'Cannot ban the owner.'}, status=status.HTTP_400_BAD_REQUEST)
        if membership.role == ChannelMember.Role.ADMIN and channel.owner_id != request.user.id:
            return Response({'error': 'Only owner can ban admins.'}, status=status.HTTP_403_FORBIDDEN)
        membership.is_banned = True
        membership.role = ChannelMember.Role.SUBSCRIBER
        membership.save(update_fields=['is_banned', 'role'])
        Channel.objects.filter(id=channel.id, subscriber_count__gt=0).update(
            subscriber_count=F('subscriber_count') - 1
        )
        return Response({'detail': 'User banned.'})


class ChannelUnbanUserView(APIView):
    """POST /api/channels/<id>/unban/ — admin/owner unbans a user."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        perm = IsChannelAdmin()
        if not perm.has_object_permission(request, self, channel):
            return Response({'error': 'Permission denied.'}, status=status.HTTP_403_FORBIDDEN)
        user_id = request.data.get('user_id')
        if not user_id:
            return Response({'error': 'user_id is required.'}, status=status.HTTP_400_BAD_REQUEST)
        membership = ChannelMember.objects.filter(
            channel=channel, user_id=user_id, is_banned=True
        ).first()
        if not membership:
            return Response({'error': 'User not found or not banned.'}, status=status.HTTP_404_NOT_FOUND)
        membership.is_banned = False
        membership.save(update_fields=['is_banned'])
        Channel.objects.filter(id=channel.id).update(subscriber_count=F('subscriber_count') + 1)
        return Response({'detail': 'User unbanned.'})


# ────────────────────────── Mute / Unmute ──────────────────────────

class ChannelMuteToggleView(APIView):
    """POST /api/channels/<id>/mute/ — toggle mute for current user."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        membership = ChannelMember.objects.filter(
            channel=channel, user=request.user, is_banned=False
        ).first()
        if not membership:
            return Response({'error': 'Not a member.'}, status=status.HTTP_403_FORBIDDEN)
        membership.is_muted = not membership.is_muted
        membership.save(update_fields=['is_muted'])
        state = 'muted' if membership.is_muted else 'unmuted'
        return Response({'detail': f'Channel {state}.', 'is_muted': membership.is_muted})


# ────────────────────────── Posts ──────────────────────────

class ChannelPostListView(generics.ListAPIView):
    """GET /api/channels/<id>/posts/ — list published posts."""
    serializer_class = ChannelPostListSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        channel_id = self.kwargs['id']
        return ChannelPost.objects.filter(
            channel_id=channel_id, is_published=True
        ).select_related('author', 'channel').prefetch_related('poll__options')

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx


class ChannelPostCreateView(APIView):
    """POST /api/channels/<id>/posts/create/ — create a post (admin/owner)."""
    permission_classes = [permissions.IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser, JSONParser]

    def post(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        perm = IsChannelAdmin()
        if not perm.has_object_permission(request, self, channel):
            return Response({'error': 'Only admins can post.'}, status=status.HTTP_403_FORBIDDEN)

        serializer = ChannelPostCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        is_scheduled = data.get('is_scheduled', False)
        media = data.get('media_file')

        post = ChannelPost.objects.create(
            channel=channel,
            author=request.user,
            post_type=data['post_type'],
            text=data.get('text', ''),
            media_file=media,
            media_filename=media.name if media else '',
            media_mime_type=getattr(media, 'content_type', '') if media else '',
            media_size=media.size if media else 0,
            is_scheduled=is_scheduled,
            scheduled_at=data.get('scheduled_at') if is_scheduled else None,
            is_published=not is_scheduled,
        )

        # Create poll if applicable
        if data['post_type'] == 'poll':
            poll = Poll.objects.create(
                post=post,
                question=data['poll_question'],
                is_anonymous=data.get('poll_is_anonymous', True),
                allows_multiple_answers=data.get('poll_allows_multiple', False),
                expires_at=data.get('poll_expires_at'),
            )
            for idx, option_text in enumerate(data['poll_options']):
                PollOption.objects.create(
                    poll=poll,
                    text=option_text,
                    order=idx,
                )

        # Broadcast to WebSocket if published immediately
        if not is_scheduled:
            from .tasks import broadcast_new_post
            broadcast_new_post.delay(str(post.id))

        out_serializer = ChannelPostListSerializer(post, context={'request': request})
        return Response(out_serializer.data, status=status.HTTP_201_CREATED)


class ChannelPostDetailView(generics.RetrieveDestroyAPIView):
    """
    GET    /api/channels/<id>/posts/<post_id>/ — post detail
    DELETE /api/channels/<id>/posts/<post_id>/ — delete post (admin/owner)
    """
    serializer_class = ChannelPostListSerializer
    permission_classes = [permissions.IsAuthenticated]
    lookup_field = 'pk'
    lookup_url_kwarg = 'post_id'

    def get_queryset(self):
        return ChannelPost.objects.filter(
            channel_id=self.kwargs['id'], is_published=True
        ).select_related('author', 'channel')

    def check_object_permissions(self, request, obj):
        super().check_object_permissions(request, obj)
        if request.method == 'DELETE':
            perm = IsChannelAdmin()
            if not perm.has_object_permission(request, self, obj):
                self.permission_denied(request, message='Only admins can delete posts.')

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx


# ────────────────────────── Pin / Unpin ──────────────────────────

class ChannelPostPinView(APIView):
    """POST /api/channels/<id>/posts/<post_id>/pin/ — pin/unpin a post."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id, post_id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        perm = IsChannelAdmin()
        if not perm.has_object_permission(request, self, channel):
            return Response({'error': 'Permission denied.'}, status=status.HTTP_403_FORBIDDEN)
        post = get_object_or_404(ChannelPost, id=post_id, channel=channel)

        if post.is_pinned:
            post.is_pinned = False
            post.save(update_fields=['is_pinned'])
            return Response({'detail': 'Post unpinned.', 'is_pinned': False})

        pinned_count = ChannelPost.objects.filter(channel=channel, is_pinned=True).count()
        if pinned_count >= 5:
            return Response(
                {'error': 'Maximum 5 pinned posts. Unpin one first.'},
                status=status.HTTP_400_BAD_REQUEST
            )
        post.is_pinned = True
        post.save(update_fields=['is_pinned'])
        return Response({'detail': 'Post pinned.', 'is_pinned': True})


class ChannelPinnedPostsView(generics.ListAPIView):
    """GET /api/channels/<id>/posts/pinned/ — list pinned posts."""
    serializer_class = ChannelPostListSerializer
    permission_classes = [permissions.IsAuthenticated]
    pagination_class = None

    def get_queryset(self):
        return ChannelPost.objects.filter(
            channel_id=self.kwargs['id'], is_pinned=True, is_published=True
        ).select_related('author')


# ────────────────────────── Post Views (read receipts) ──────────────────────────

class PostViewRegisterView(APIView):
    """POST /api/channels/<id>/posts/<post_id>/view/ — mark post as viewed."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id, post_id):
        post = get_object_or_404(ChannelPost, id=post_id, channel_id=id, is_published=True)
        _, created = PostView.objects.get_or_create(post=post, user=request.user)
        if created:
            ChannelPost.objects.filter(id=post.id).update(view_count=F('view_count') + 1)
        return Response({'detail': 'Viewed.'}, status=status.HTTP_200_OK)


# ────────────────────────── Reactions ──────────────────────────

class PostReactionToggleView(APIView):
    """POST /api/channels/<id>/posts/<post_id>/react/ — toggle reaction."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id, post_id):
        post = get_object_or_404(ChannelPost, id=post_id, channel_id=id, is_published=True)
        emoji = request.data.get('emoji', '')
        if not emoji:
            return Response({'error': 'emoji is required.'}, status=status.HTTP_400_BAD_REQUEST)

        existing = PostReaction.objects.filter(post=post, user=request.user, emoji=emoji).first()
        if existing:
            existing.delete()
            ChannelPost.objects.filter(id=post.id, reaction_count__gt=0).update(
                reaction_count=F('reaction_count') - 1
            )
            return Response({'detail': 'Reaction removed.', 'action': 'removed'})

        PostReaction.objects.create(post=post, user=request.user, emoji=emoji)
        ChannelPost.objects.filter(id=post.id).update(reaction_count=F('reaction_count') + 1)
        return Response({'detail': 'Reaction added.', 'action': 'added'}, status=status.HTTP_201_CREATED)


# ────────────────────────── Comments ──────────────────────────

class PostCommentListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/channels/<id>/posts/<post_id>/comments/ — list comments
    POST /api/channels/<id>/posts/<post_id>/comments/ — add comment
    """
    serializer_class = PostCommentSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return PostComment.objects.filter(
            post_id=self.kwargs['post_id'],
            post__channel_id=self.kwargs['id'],
            parent__isnull=True,
        ).select_related('author')

    def perform_create(self, serializer):
        post = get_object_or_404(
            ChannelPost,
            id=self.kwargs['post_id'],
            channel_id=self.kwargs['id'],
            is_published=True,
        )
        if not post.channel.comments_enabled:
            raise PermissionDenied('Comments are disabled on this channel.')

        # Verify membership
        if not ChannelMember.objects.filter(
            channel=post.channel, user=self.request.user, is_banned=False
        ).exists():
            raise PermissionDenied('You must be a subscriber to comment.')

        serializer.save(post=post, author=self.request.user)
        ChannelPost.objects.filter(id=post.id).update(comment_count=F('comment_count') + 1)


class PostCommentDeleteView(generics.DestroyAPIView):
    """DELETE /api/channels/<id>/posts/<post_id>/comments/<comment_id>/"""
    permission_classes = [permissions.IsAuthenticated]
    lookup_url_kwarg = 'comment_id'

    def get_queryset(self):
        return PostComment.objects.filter(
            post_id=self.kwargs['post_id'],
            post__channel_id=self.kwargs['id'],
        )

    def check_object_permissions(self, request, obj):
        super().check_object_permissions(request, obj)
        is_author = obj.author_id == request.user.id
        perm = IsChannelAdmin()
        is_admin = perm.has_object_permission(request, self, obj.post)
        if not (is_author or is_admin):
            self.permission_denied(request, message='Cannot delete this comment.')

    def perform_destroy(self, instance):
        post = instance.post
        instance.delete()
        ChannelPost.objects.filter(id=post.id, comment_count__gt=0).update(
            comment_count=F('comment_count') - 1
        )


# ────────────────────────── Poll Voting ──────────────────────────

class PollVoteView(APIView):
    """POST /api/channels/<id>/posts/<post_id>/vote/ — vote on a poll."""
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, id, post_id):
        post = get_object_or_404(ChannelPost, id=post_id, channel_id=id, post_type='poll')
        poll = get_object_or_404(Poll, post=post)

        if poll.is_expired:
            return Response({'error': 'This poll has expired.'}, status=status.HTTP_400_BAD_REQUEST)

        if not ChannelMember.objects.filter(
            channel_id=id, user=request.user, is_banned=False
        ).exists():
            return Response({'error': 'You must be a subscriber to vote.'}, status=status.HTTP_403_FORBIDDEN)

        option_ids = request.data.get('option_ids', [])
        if not option_ids:
            return Response({'error': 'option_ids is required.'}, status=status.HTTP_400_BAD_REQUEST)

        if not poll.allows_multiple_answers and len(option_ids) > 1:
            return Response(
                {'error': 'This poll only allows a single answer.'},
                status=status.HTTP_400_BAD_REQUEST
            )

        # Remove previous votes
        old_votes = PollVote.objects.filter(poll=poll, user=request.user)
        old_option_ids = list(old_votes.values_list('option_id', flat=True))
        old_count = old_votes.count()
        old_votes.delete()

        # Decrement old option counts
        if old_option_ids:
            PollOption.objects.filter(id__in=old_option_ids).update(vote_count=F('vote_count') - 1)

        # Cast new votes
        valid_options = PollOption.objects.filter(poll=poll, id__in=option_ids)
        if valid_options.count() != len(option_ids):
            return Response({'error': 'Invalid option_ids.'}, status=status.HTTP_400_BAD_REQUEST)

        new_votes = []
        for option in valid_options:
            new_votes.append(PollVote(poll=poll, option=option, user=request.user))
        PollVote.objects.bulk_create(new_votes)

        # Update counts
        PollOption.objects.filter(id__in=option_ids).update(vote_count=F('vote_count') + 1)
        net_change = len(option_ids) - old_count
        if net_change != 0:
            Poll.objects.filter(id=poll.id).update(total_votes=F('total_votes') + net_change)

        poll.refresh_from_db()
        serializer = PollSerializer(poll, context={'request': request})
        return Response(serializer.data)


# ────────────────────────── Channel Stats ──────────────────────────

class ChannelStatsView(APIView):
    """GET /api/channels/<id>/stats/ — channel statistics (admin/owner)."""
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request, id):
        channel = get_object_or_404(Channel, id=id, is_active=True)
        perm = IsChannelAdmin()
        if not perm.has_object_permission(request, self, channel):
            return Response({'error': 'Permission denied.'}, status=status.HTTP_403_FORBIDDEN)

        now = timezone.now()
        posts = ChannelPost.objects.filter(channel=channel, is_published=True)

        total_views = posts.aggregate(total=Sum('view_count'))['total'] or 0
        total_reactions = posts.aggregate(total=Sum('reaction_count'))['total'] or 0

        growth_7 = ChannelMember.objects.filter(
            channel=channel, is_banned=False,
            joined_at__gte=now - timedelta(days=7)
        ).count()
        growth_30 = ChannelMember.objects.filter(
            channel=channel, is_banned=False,
            joined_at__gte=now - timedelta(days=30)
        ).count()

        top_posts = posts.order_by('-view_count')[:5]

        data = {
            'channel_id': channel.id,
            'channel_name': channel.name,
            'subscriber_count': channel.subscriber_count,
            'total_posts': posts.count(),
            'total_views': total_views,
            'total_reactions': total_reactions,
            'growth_last_7_days': growth_7,
            'growth_last_30_days': growth_30,
            'top_posts': ChannelPostListSerializer(
                top_posts, many=True, context={'request': request}
            ).data,
        }
        return Response(data)


# ────────────────────────── My Channels ──────────────────────────

class MyChannelsView(generics.ListAPIView):
    """GET /api/channels/me/ — channels the user is subscribed to."""
    serializer_class = ChannelListSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return Channel.objects.filter(
            members__user=self.request.user,
            members__is_banned=False,
            is_active=True,
        ).distinct()

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx
