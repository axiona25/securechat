from rest_framework import generics, status, permissions
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.pagination import CursorPagination
from django.shortcuts import get_object_or_404
from django.utils import timezone

from .models import DeviceToken, NotificationPreference, MuteRule, Notification
from .serializers import (
    DeviceTokenSerializer, DeviceTokenDeleteSerializer,
    NotificationPreferenceSerializer, MuteRuleSerializer,
    NotificationSerializer, BadgeCountSerializer,
)
from .services import NotificationService


# ────────────────────────── Device Tokens ──────────────────────────

class RegisterDeviceTokenView(generics.CreateAPIView):
    """
    POST /api/notifications/devices/register/
    Register or update a device FCM token.
    """
    serializer_class = DeviceTokenSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx


class UnregisterDeviceTokenView(APIView):
    """
    POST /api/notifications/devices/unregister/
    Remove a device token (on logout or app uninstall).
    Body: { "device_id": "..." }
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        serializer = DeviceTokenDeleteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        device_id = serializer.validated_data['device_id']

        deleted, _ = DeviceToken.objects.filter(
            user=request.user,
            device_id=device_id,
        ).delete()

        if deleted:
            return Response({'detail': 'Device token removed.'})
        return Response({'detail': 'Device not found.'}, status=status.HTTP_404_NOT_FOUND)


class MyDevicesView(generics.ListAPIView):
    """
    GET /api/notifications/devices/
    List all registered devices for the current user.
    """
    serializer_class = DeviceTokenSerializer
    permission_classes = [permissions.IsAuthenticated]
    pagination_class = None

    def get_queryset(self):
        return DeviceToken.objects.filter(user=self.request.user).order_by('-last_used_at')


# ────────────────────────── Notification Preferences ──────────────────────────

class NotificationPreferencesView(APIView):
    """
    GET  /api/notifications/preferences/ — get current preferences
    PATCH /api/notifications/preferences/ — update preferences
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        prefs, _ = NotificationPreference.objects.get_or_create(user=request.user)
        serializer = NotificationPreferenceSerializer(prefs)
        return Response(serializer.data)

    def patch(self, request):
        prefs, _ = NotificationPreference.objects.get_or_create(user=request.user)
        serializer = NotificationPreferenceSerializer(prefs, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)


# ────────────────────────── Mute Rules ──────────────────────────

class MuteRuleListCreateView(generics.ListCreateAPIView):
    """
    GET  /api/notifications/mute/ — list active mute rules
    POST /api/notifications/mute/ — create/update mute rule
    Body: { "target_type": "conversation|group|channel", "target_id": "uuid", "muted_until": null }
    """
    serializer_class = MuteRuleSerializer
    permission_classes = [permissions.IsAuthenticated]
    pagination_class = None

    def get_queryset(self):
        return MuteRule.objects.filter(user=self.request.user).order_by('-created_at')

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx


class MuteRuleDeleteView(APIView):
    """
    DELETE /api/notifications/mute/<target_type>/<target_id>/
    Unmute a specific target.
    """
    permission_classes = [permissions.IsAuthenticated]

    def delete(self, request, target_type, target_id):
        deleted, _ = MuteRule.objects.filter(
            user=request.user,
            target_type=target_type,
            target_id=target_id,
        ).delete()
        if deleted:
            return Response({'detail': 'Unmuted.'})
        return Response({'detail': 'Mute rule not found.'}, status=status.HTTP_404_NOT_FOUND)


# ────────────────────────── Notification History ──────────────────────────

class NotificationCursorPagination(CursorPagination):
    ordering = '-created_at'


class NotificationListView(generics.ListAPIView):
    """
    GET /api/notifications/
    List notification history for current user.
    Query params: ?type=new_message&unread=true
    """
    serializer_class = NotificationSerializer
    permission_classes = [permissions.IsAuthenticated]
    pagination_class = NotificationCursorPagination

    def get_queryset(self):
        qs = Notification.objects.filter(recipient=self.request.user).order_by('-created_at')
        notif_type = self.request.query_params.get('type')
        unread = self.request.query_params.get('unread')
        if notif_type:
            qs = qs.filter(notification_type=notif_type)
        if unread and unread.lower() in ('true', '1'):
            qs = qs.filter(is_read=False)
        return qs.select_related('sender')


class NotificationMarkReadView(APIView):
    """
    POST /api/notifications/<id>/read/
    Mark a single notification as read.
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, notification_id):
        notification = get_object_or_404(
            Notification, id=notification_id, recipient=request.user
        )
        notification.mark_as_read()
        return Response({'detail': 'Marked as read.'})


class NotificationMarkAllReadView(APIView):
    """
    POST /api/notifications/read-all/
    Mark all notifications as read.
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        updated = Notification.objects.filter(
            recipient=request.user, is_read=False
        ).update(is_read=True, read_at=timezone.now())
        return Response({'detail': f'{updated} notifications marked as read.'})


class NotificationDeleteView(APIView):
    """
    DELETE /api/notifications/<id>/delete/
    Delete a single notification.
    """
    permission_classes = [permissions.IsAuthenticated]

    def delete(self, request, notification_id):
        deleted, _ = Notification.objects.filter(
            id=notification_id, recipient=request.user
        ).delete()
        if deleted:
            return Response({'detail': 'Deleted.'})
        return Response({'detail': 'Not found.'}, status=status.HTTP_404_NOT_FOUND)


class NotificationClearAllView(APIView):
    """
    DELETE /api/notifications/clear/
    Delete all read notifications.
    """
    permission_classes = [permissions.IsAuthenticated]

    def delete(self, request):
        deleted, _ = Notification.objects.filter(
            recipient=request.user, is_read=True
        ).delete()
        return Response({'detail': f'{deleted} notifications cleared.'})


# ────────────────────────── Badge Count ──────────────────────────

class BadgeCountView(APIView):
    """
    GET /api/notifications/badge/
    Get unread notification count and breakdown by type.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        data = NotificationService.get_badge_count(request.user.id)
        return Response(data)
