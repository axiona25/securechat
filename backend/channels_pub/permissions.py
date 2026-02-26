from rest_framework.permissions import BasePermission
from .models import ChannelMember


class IsChannelOwner(BasePermission):
    """Only the channel owner can perform this action."""

    def has_object_permission(self, request, view, obj):
        channel = obj if hasattr(obj, 'owner') else getattr(obj, 'channel', None)
        if channel is None:
            return False
        return channel.owner_id == request.user.id


class IsChannelAdmin(BasePermission):
    """Channel owner or admin can perform this action."""

    def has_object_permission(self, request, view, obj):
        channel = obj if hasattr(obj, 'owner') else getattr(obj, 'channel', None)
        if channel is None:
            return False
        if channel.owner_id == request.user.id:
            return True
        return ChannelMember.objects.filter(
            channel=channel,
            user=request.user,
            role__in=[ChannelMember.Role.OWNER, ChannelMember.Role.ADMIN],
            is_banned=False,
        ).exists()


class IsChannelMember(BasePermission):
    """Any non-banned channel member can perform this action."""

    def has_object_permission(self, request, view, obj):
        channel = obj if hasattr(obj, 'owner') else getattr(obj, 'channel', None)
        if channel is None:
            return False
        return ChannelMember.objects.filter(
            channel=channel,
            user=request.user,
            is_banned=False,
        ).exists()
