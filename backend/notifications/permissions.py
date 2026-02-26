from rest_framework.permissions import BasePermission


class IsNotificationRecipient(BasePermission):
    """Only the notification recipient can access it."""

    def has_object_permission(self, request, view, obj):
        return obj.recipient_id == request.user.id
