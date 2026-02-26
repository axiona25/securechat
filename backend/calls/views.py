from django.db.models import Q
from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework.pagination import CursorPagination
from .models import Call, CallParticipant, ICEServer
from .serializers import CallSerializer, CallLogSerializer


class CallLogPagination(CursorPagination):
    page_size = 30
    ordering = '-created_at'


class CallLogView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """
        Get call history for current user.
        Filters: ?type=audio|video, ?status=missed|received|made, ?search=name
        """
        calls = Call.objects.filter(
            Q(initiated_by=request.user) | Q(participants__user=request.user)
        ).select_related('initiated_by').prefetch_related(
            'participants__user'
        ).distinct().order_by('-created_at')

        # Filters
        call_type = request.query_params.get('type')
        if call_type in ('audio', 'video'):
            calls = calls.filter(call_type=call_type)

        status_filter = request.query_params.get('status')
        if status_filter == 'missed':
            calls = calls.filter(status='missed').exclude(initiated_by=request.user)
        elif status_filter == 'received':
            calls = calls.filter(status='ended').exclude(initiated_by=request.user)
        elif status_filter == 'made':
            calls = calls.filter(initiated_by=request.user)

        paginator = CallLogPagination()
        page = paginator.paginate_queryset(calls, request)
        serializer = CallLogSerializer(page, many=True, context={'request': request})
        return paginator.get_paginated_response(serializer.data)


class CallDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, call_id):
        """Get details of a specific call"""
        try:
            call = Call.objects.prefetch_related('participants__user').filter(
                Q(id=call_id) & (
                    Q(initiated_by=request.user) | Q(participants__user=request.user)
                )
            ).distinct().get()
        except Call.DoesNotExist:
            return Response({'error': 'Chiamata non trovata.'}, status=status.HTTP_404_NOT_FOUND)

        serializer = CallSerializer(call, context={'request': request})
        return Response(serializer.data)


class ICEServersView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """Get STUN/TURN server configuration for WebRTC"""
        servers = ICEServer.objects.filter(is_active=True)
        ice_config = [s.to_webrtc_config() for s in servers]

        # Add default STUN servers if none configured
        if not ice_config:
            ice_config = [
                {'urls': 'stun:stun.l.google.com:19302'},
                {'urls': 'stun:stun1.l.google.com:19302'},
                {'urls': 'stun:stun2.l.google.com:19302'},
            ]

        return Response({'ice_servers': ice_config})


class MissedCallsCountView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        """Get count of missed calls"""
        count = Call.objects.filter(
            participants__user=request.user,
            status='missed',
        ).exclude(initiated_by=request.user).count()

        return Response({'missed_calls': count})
