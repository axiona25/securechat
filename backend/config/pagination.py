"""
Default cursor pagination for the API.
Uses created_at (not 'created') so models with created_at work with the global default.
"""
from rest_framework.pagination import CursorPagination


class DefaultCursorPagination(CursorPagination):
    page_size = 50
    ordering = '-created_at'
