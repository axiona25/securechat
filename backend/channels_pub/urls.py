from django.urls import path
from . import views

app_name = 'channels_pub'

urlpatterns = [
    # Categories
    path('categories/', views.ChannelCategoryListView.as_view(), name='category-list'),

    # My channels
    path('me/', views.MyChannelsView.as_view(), name='my-channels'),

    # Join by invite code
    path('join/<str:invite_code>/', views.ChannelJoinByInviteView.as_view(), name='join-by-invite'),

    # Channel CRUD
    path('', views.ChannelListCreateView.as_view(), name='channel-list-create'),
    path('<uuid:id>/', views.ChannelDetailView.as_view(), name='channel-detail'),

    # Subscribe / Unsubscribe
    path('<uuid:id>/subscribe/', views.ChannelSubscribeView.as_view(), name='channel-subscribe'),
    path('<uuid:id>/unsubscribe/', views.ChannelUnsubscribeView.as_view(), name='channel-unsubscribe'),

    # Invite management
    path('<uuid:id>/regenerate-invite/', views.ChannelRegenerateInviteView.as_view(), name='regenerate-invite'),

    # Members management
    path('<uuid:id>/members/', views.ChannelMembersView.as_view(), name='channel-members'),
    path('<uuid:id>/promote/', views.ChannelPromoteAdminView.as_view(), name='promote-admin'),
    path('<uuid:id>/demote/', views.ChannelDemoteAdminView.as_view(), name='demote-admin'),
    path('<uuid:id>/ban/', views.ChannelBanUserView.as_view(), name='ban-user'),
    path('<uuid:id>/unban/', views.ChannelUnbanUserView.as_view(), name='unban-user'),

    # Mute
    path('<uuid:id>/mute/', views.ChannelMuteToggleView.as_view(), name='mute-toggle'),

    # Posts
    path('<uuid:id>/posts/', views.ChannelPostListView.as_view(), name='post-list'),
    path('<uuid:id>/posts/create/', views.ChannelPostCreateView.as_view(), name='post-create'),
    path('<uuid:id>/posts/pinned/', views.ChannelPinnedPostsView.as_view(), name='pinned-posts'),
    path('<uuid:id>/posts/<uuid:post_id>/', views.ChannelPostDetailView.as_view(), name='post-detail'),
    path('<uuid:id>/posts/<uuid:post_id>/pin/', views.ChannelPostPinView.as_view(), name='post-pin'),
    path('<uuid:id>/posts/<uuid:post_id>/view/', views.PostViewRegisterView.as_view(), name='post-view'),
    path('<uuid:id>/posts/<uuid:post_id>/react/', views.PostReactionToggleView.as_view(), name='post-react'),

    # Comments
    path('<uuid:id>/posts/<uuid:post_id>/comments/', views.PostCommentListCreateView.as_view(), name='post-comments'),
    path('<uuid:id>/posts/<uuid:post_id>/comments/<uuid:comment_id>/', views.PostCommentDeleteView.as_view(), name='comment-delete'),

    # Poll voting
    path('<uuid:id>/posts/<uuid:post_id>/vote/', views.PollVoteView.as_view(), name='poll-vote'),

    # Stats
    path('<uuid:id>/stats/', views.ChannelStatsView.as_view(), name='channel-stats'),
]
