"""
Dual authentication: supports both JWT and Django session auth.
The admin panel can be used via:
1. JWT tokens (Authorization: Bearer <token>) — for React frontend
2. Session cookies — for direct browser access
"""
from rest_framework.authentication import SessionAuthentication
from rest_framework_simplejwt.authentication import JWTAuthentication


class AdminJWTAuthentication(JWTAuthentication):
    """JWT auth that only allows staff users."""

    def authenticate(self, request):
        result = super().authenticate(request)
        if result is None:
            return None
        user, token = result
        if not user.is_staff:
            return None
        return result


class AdminSessionAuthentication(SessionAuthentication):
    """Session auth that only allows staff users."""

    def authenticate(self, request):
        result = super().authenticate(request)
        if result is None:
            return None
        user, _ = result
        if not user.is_staff:
            return None
        return result
