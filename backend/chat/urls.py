from django.urls import path, include
from . import views

urlpatterns = [
    # E2EE encrypted media (zero-knowledge)
    path('', include('chat.media_urls')),
    path('lock-pin/', views.LockPinView.as_view(), name='lock-pin'),
    # Conversations (POST on conversation-list also creates private conv with body: participants + conv_type)
    path('conversations/', views.ConversationListView.as_view(), name='conversation-list'),
    path('conversations/create/', views.CreatePrivateConversationView.as_view(), name='create-private'),
    path('conversations/<uuid:conversation_id>/', views.ConversationDetailView.as_view(), name='conversation-detail'),
    path('conversations/<uuid:conversation_id>/messages/', views.MessageListView.as_view(), name='message-list'),
    path('conversations/<uuid:conversation_id>/read/', views.MarkAsReadView.as_view(), name='mark-as-read'),
    path('conversations/<uuid:conversation_id>/mute/', views.ConversationMuteView.as_view(), name='conversation-mute'),
    path('conversations/<uuid:conversation_id>/clear/', views.ConversationClearView.as_view(), name='conversation-clear'),
    path('conversations/<uuid:conversation_id>/leave/', views.ConversationLeaveView.as_view(), name='conversation-leave'),
    path('conversations/<uuid:conversation_id>/delete-for-all/', views.ConversationDeleteForAllView.as_view()),
    path('conversations/<uuid:conversation_id>/avatar/', views.ConversationAvatarView.as_view(), name='conversation-avatar'),
    path('conversations/<uuid:conversation_id>/participants/', views.ConversationParticipantsView.as_view(), name='conversation-participants'),
    path('conversations/<uuid:conversation_id>/participants/<int:user_id>/', views.ConversationParticipantDetailView.as_view(), name='conversation-participant-detail'),
    # Chat features
    path('conversations/<uuid:conversation_id>/lock/', views.ConversationLockView.as_view(), name='conversation-lock'),
    path('conversations/<uuid:conversation_id>/favorite/', views.ConversationFavoriteView.as_view(), name='conversation-favorite'),
    path('conversations/<uuid:conversation_id>/lock-secret/', views.LockChatView.as_view(), name='lock-chat'),
    path('conversations/<uuid:conversation_id>/unlock/', views.UnlockChatView.as_view(), name='unlock-chat'),
    path('conversations/<uuid:conversation_id>/location/', views.LocationShareView.as_view(), name='share-location'),
    path('conversations/<uuid:conversation_id>/event/', views.CalendarEventView.as_view(), name='create-event'),
    path('conversations/<uuid:conversation_id>/search/', views.SearchMessagesView.as_view(), name='search-messages'),
    # Attachments
    path('upload/', views.AttachmentUploadView.as_view(), name='upload-attachment'),
    path('media/<path:file_path>', views.MediaServeView.as_view(), name='media-serve'),
    path('convert/<uuid:attachment_id>/', views.OfficeConvertView.as_view(), name='office-convert'),
    # Messages
    path('messages/<uuid:message_id>/react/', views.ReactionView.as_view(), name='message-react'),
    path('link-preview/', views.LinkPreviewView.as_view(), name='link-preview'),
    # Groups
    path('groups/', views.CreateGroupView.as_view(), name='create-group'),
    path('groups/<uuid:conversation_id>/members/', views.GroupMembersView.as_view(), name='group-members'),
    path('groups/join/<str:invite_code>/', views.GroupJoinView.as_view(), name='group-join'),
    # Stories
    path('stories/', views.StoryCreateView.as_view(), name='story-create'),
    path('stories/feed/', views.StoryFeedView.as_view(), name='story-feed'),
    path('stories/<uuid:story_id>/view/', views.StoryViewRegisterView.as_view(), name='story-view'),
    path('stories/<uuid:story_id>/viewers/', views.StoryViewersView.as_view(), name='story-viewers'),
    path('stories/<uuid:story_id>/', views.StoryDeleteView.as_view(), name='story-delete'),
]
