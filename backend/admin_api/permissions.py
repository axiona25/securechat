from rest_framework.permissions import BasePermission


class IsAdminStaff(BasePermission):
    """
    Allow access only to staff users.
    Supports both JWT auth and Django session auth.
    """

    def has_permission(self, request, view):
        return (
            request.user
            and request.user.is_authenticated
            and request.user.is_staff
        )


class IsSuperAdmin(BasePermission):
    """Allow access only to superusers."""

    def has_permission(self, request, view):
        return (
            request.user
            and request.user.is_authenticated
            and request.user.is_superuser
        )
