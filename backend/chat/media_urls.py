from django.urls import path
from chat.media_views import (
    EncryptedMediaUploadView,
    EncryptedMediaDownloadView,
    EncryptedThumbnailDownloadView,
    AttachmentKeyView,
)

urlpatterns = [
    path('media/upload/', EncryptedMediaUploadView.as_view(), name='media-upload'),
    path('media/<uuid:attachment_id>/download/', EncryptedMediaDownloadView.as_view(), name='media-download'),
    path('media/<uuid:attachment_id>/thumbnail/', EncryptedThumbnailDownloadView.as_view(), name='media-thumbnail'),
    path('media/<uuid:attachment_id>/key/', AttachmentKeyView.as_view(), name='media-key'),
]
