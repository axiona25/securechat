"""
SecureChat — Encrypted Media Upload/Download API
Il server riceve e archivia SOLO blob cifrati. Zero-knowledge.
"""
import uuid
import os
import logging

from django.conf import settings
from django.http import FileResponse, Http404
from rest_framework import status
from rest_framework.parsers import MultiPartParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from chat.models import Attachment, Conversation, ConversationParticipant, Message

logger = logging.getLogger(__name__)

# Max file sizes
MAX_FILE_SIZE = 100 * 1024 * 1024  # 100 MB
MAX_THUMBNAIL_SIZE = 512 * 1024     # 512 KB


def _get_encrypted_media_path(instance_id: str, filename: str) -> str:
    """Generate storage path for encrypted media: encrypted_media/<year>/<month>/<uuid>/<filename>"""
    from datetime import datetime
    now = datetime.now()
    return f"encrypted_media/{now.year}/{now.month:02d}/{instance_id}/{filename}"


def _save_file(uploaded_file, relative_path: str) -> str:
    """
    Save an uploaded file to MEDIA_ROOT or storage backend.
    Returns the relative path for the FileField.
    """
    from django.core.files.storage import default_storage
    from django.core.files.base import ContentFile

    content = uploaded_file.read()
    saved_path = default_storage.save(relative_path, ContentFile(content))
    return saved_path


class EncryptedMediaUploadView(APIView):
    """
    POST /api/chat/media/upload/

    Upload encrypted media blob + optional encrypted thumbnail.
    The server stores ONLY encrypted data — it cannot decrypt anything.

    Request (multipart/form-data):
        - encrypted_file: The encrypted file blob (required)
        - encrypted_thumbnail: Encrypted thumbnail blob (optional, for images/videos)
        - conversation_id: UUID of the conversation (required)
        - encrypted_file_key: Base64-encoded encrypted file key (required)
        - encrypted_metadata: Base64-encoded encrypted file metadata (required)
        - file_hash: SHA-256 hash of the ORIGINAL plaintext file (required, for integrity check)
        - encrypted_file_size: Size of the original plaintext file in bytes (required)

    Response:
        - attachment_id: UUID
        - encrypted_file_url: URL to download the encrypted file
        - encrypted_thumbnail_url: URL to download the encrypted thumbnail (if uploaded)
    """
    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser]

    def post(self, request):
        encrypted_file = request.FILES.get('encrypted_file')
        if not encrypted_file:
            return Response(
                {'error': 'encrypted_file is required'},
                status=status.HTTP_400_BAD_REQUEST
            )

        conversation_id = request.data.get('conversation_id')
        encrypted_file_key = request.data.get('encrypted_file_key')
        encrypted_metadata = request.data.get('encrypted_metadata')
        file_hash = request.data.get('file_hash')
        encrypted_file_size = request.data.get('encrypted_file_size')

        if not all([conversation_id, encrypted_file_key, encrypted_metadata, file_hash]):
            return Response(
                {'error': 'conversation_id, encrypted_file_key, encrypted_metadata, and file_hash are required'},
                status=status.HTTP_400_BAD_REQUEST
            )

        if encrypted_file.size > MAX_FILE_SIZE:
            return Response(
                {'error': f'File too large. Maximum size is {MAX_FILE_SIZE // (1024*1024)} MB'},
                status=status.HTTP_400_BAD_REQUEST
            )

        try:
            conversation = Conversation.objects.get(id=conversation_id)
        except Conversation.DoesNotExist:
            return Response(
                {'error': 'Conversation not found'},
                status=status.HTTP_404_NOT_FOUND
            )

        is_participant = ConversationParticipant.objects.filter(
            conversation=conversation,
            user=request.user
        ).exists()

        if not is_participant:
            return Response(
                {'error': 'You are not a participant of this conversation'},
                status=status.HTTP_403_FORBIDDEN
            )

        attachment_id = uuid.uuid4()

        encrypted_file_path = _get_encrypted_media_path(str(attachment_id), 'encrypted_blob')
        saved_file_path = _save_file(encrypted_file, encrypted_file_path)

        encrypted_thumbnail = request.FILES.get('encrypted_thumbnail')
        saved_thumbnail_path = None
        if encrypted_thumbnail:
            if encrypted_thumbnail.size > MAX_THUMBNAIL_SIZE:
                return Response(
                    {'error': f'Thumbnail too large. Maximum size is {MAX_THUMBNAIL_SIZE // 1024} KB'},
                    status=status.HTTP_400_BAD_REQUEST
                )
            thumbnail_path = _get_encrypted_media_path(str(attachment_id), 'encrypted_thumb')
            saved_thumbnail_path = _save_file(encrypted_thumbnail, thumbnail_path)

        attachment = Attachment.objects.create(
            id=attachment_id,
            message=None,
            file=saved_file_path,
            file_name='encrypted',
            file_size=int(encrypted_file_size) if encrypted_file_size else encrypted_file.size,
            mime_type='application/octet-stream',
            thumbnail=saved_thumbnail_path if saved_thumbnail_path else None,
            encrypted_file_key=encrypted_file_key,
            encrypted_metadata=encrypted_metadata,
            file_hash=file_hash,
            is_encrypted=True,
            uploaded_by=request.user,
        )

        base_url = request.build_absolute_uri('/').rstrip('/')
        response_data = {
            'attachment_id': str(attachment.id),
            'encrypted_file_url': f'{base_url}/api/chat/media/{attachment.id}/download/',
            'status': 'uploaded',
        }

        if saved_thumbnail_path:
            response_data['encrypted_thumbnail_url'] = f'{base_url}/api/chat/media/{attachment.id}/thumbnail/'

        logger.info(
            f"Encrypted media uploaded: attachment={attachment.id}, "
            f"user={request.user.id}, conversation={conversation_id}, "
            f"encrypted_size={encrypted_file.size}"
        )

        return Response(response_data, status=status.HTTP_201_CREATED)


class EncryptedMediaDownloadView(APIView):
    """
    GET /api/chat/media/<attachment_id>/download/

    Download encrypted media blob. Only conversation participants can download.
    The downloaded data is encrypted — the server never decrypts it.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, attachment_id):
        try:
            attachment = Attachment.objects.get(id=attachment_id)
        except Attachment.DoesNotExist:
            raise Http404("Attachment not found")

        message = Message.objects.filter(attachments=attachment).first()
        if message:
            is_participant = ConversationParticipant.objects.filter(
                conversation=message.conversation,
                user=request.user
            ).exists()
            if not is_participant:
                return Response(
                    {'error': 'Access denied'},
                    status=status.HTTP_403_FORBIDDEN
                )
        else:
            if attachment.uploaded_by_id != request.user.id:
                return Response(
                    {'error': 'Access denied'},
                    status=status.HTTP_403_FORBIDDEN
                )

        file_path = attachment.file.path if hasattr(attachment.file, 'path') else None

        if file_path and os.path.exists(file_path):
            response = FileResponse(
                open(file_path, 'rb'),
                content_type='application/octet-stream'
            )
            response['Content-Disposition'] = f'attachment; filename="encrypted_{attachment_id}"'
            response['X-File-Hash'] = attachment.file_hash or ''
            response['X-Is-Encrypted'] = 'true'
            return response

        if hasattr(attachment.file, 'url'):
            return Response({
                'download_url': attachment.file.url,
                'file_hash': attachment.file_hash or '',
                'is_encrypted': True,
            })

        raise Http404("File not found on storage")


class EncryptedThumbnailDownloadView(APIView):
    """
    GET /api/chat/media/<attachment_id>/thumbnail/

    Download encrypted thumbnail. Same access control as media download.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, attachment_id):
        try:
            attachment = Attachment.objects.get(id=attachment_id)
        except Attachment.DoesNotExist:
            raise Http404("Attachment not found")

        message = Message.objects.filter(attachments=attachment).first()
        if message:
            is_participant = ConversationParticipant.objects.filter(
                conversation=message.conversation,
                user=request.user
            ).exists()
            if not is_participant:
                return Response({'error': 'Access denied'}, status=status.HTTP_403_FORBIDDEN)
        else:
            if attachment.uploaded_by_id != request.user.id:
                return Response({'error': 'Access denied'}, status=status.HTTP_403_FORBIDDEN)

        if not attachment.thumbnail:
            raise Http404("No thumbnail available")

        thumb_path = attachment.thumbnail.path if hasattr(attachment.thumbnail, 'path') else None

        if thumb_path and os.path.exists(thumb_path):
            response = FileResponse(
                open(thumb_path, 'rb'),
                content_type='application/octet-stream'
            )
            response['X-Is-Encrypted'] = 'true'
            return response

        if hasattr(attachment.thumbnail, 'url'):
            return Response({
                'download_url': attachment.thumbnail.url,
                'is_encrypted': True,
            })

        raise Http404("Thumbnail not found on storage")


class AttachmentKeyView(APIView):
    """
    GET /api/chat/media/<attachment_id>/key/

    Get the encrypted file key and metadata for an attachment.
    The receiver needs this to decrypt the file after downloading.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, attachment_id):
        try:
            attachment = Attachment.objects.get(id=attachment_id)
        except Attachment.DoesNotExist:
            raise Http404("Attachment not found")

        message = Message.objects.filter(attachments=attachment).first()
        if message:
            is_participant = ConversationParticipant.objects.filter(
                conversation=message.conversation,
                user=request.user
            ).exists()
            if not is_participant:
                return Response({'error': 'Access denied'}, status=status.HTTP_403_FORBIDDEN)
        else:
            if attachment.uploaded_by_id != request.user.id:
                return Response({'error': 'Access denied'}, status=status.HTTP_403_FORBIDDEN)

        return Response({
            'attachment_id': str(attachment.id),
            'encrypted_file_key': attachment.encrypted_file_key,
            'encrypted_metadata': attachment.encrypted_metadata,
            'file_hash': attachment.file_hash,
            'is_encrypted': attachment.is_encrypted,
        })
