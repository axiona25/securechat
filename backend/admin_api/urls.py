from django.urls import path
from . import views

app_name = 'admin_api'

urlpatterns = [
    # Auth
    path('auth/login/', views.AdminLoginView.as_view(), name='admin-login'),
    path('auth/me/', views.AdminMeView.as_view(), name='admin-me'),

    # Dashboard
    path('dashboard/stats/', views.DashboardStatsView.as_view(), name='dashboard-stats'),
    path('dashboard/charts/', views.DashboardChartsView.as_view(), name='dashboard-charts'),
    path('dashboard/threats/', views.DashboardRecentThreatsView.as_view(), name='dashboard-threats'),

    # Users
    path('users/', views.AdminUserListView.as_view(), name='user-list'),
    path('users/<int:id>/', views.AdminUserDetailView.as_view(), name='user-detail'),
    path('users/<int:id>/action/', views.AdminUserActionView.as_view(), name='user-action'),

    # Conversations
    path('conversations/', views.AdminConversationListView.as_view(), name='conversation-list'),
    path('conversations/<uuid:id>/', views.AdminConversationDetailView.as_view(), name='conversation-detail'),
    path('conversations/<uuid:id>/delete/', views.AdminConversationDeleteView.as_view(), name='conversation-delete'),

    # Channels
    path('channels/', views.AdminChannelListView.as_view(), name='channel-list'),
    path('channels/<uuid:id>/action/', views.AdminChannelActionView.as_view(), name='channel-action'),
    path('channels/<uuid:id>/delete/', views.AdminChannelDeleteView.as_view(), name='channel-delete'),

    # Channel Categories
    path('channel-categories/', views.AdminChannelCategoryListCreateView.as_view(), name='category-list-create'),
    path('channel-categories/<int:id>/', views.AdminChannelCategoryDetailView.as_view(), name='category-detail'),

    # Calls
    path('calls/', views.AdminCallListView.as_view(), name='call-list'),
    path('calls/stats/', views.AdminCallStatsView.as_view(), name='call-stats'),

    # Security
    path('security/threats/', views.AdminThreatListView.as_view(), name='threat-list'),
    path('security/threats/<uuid:id>/resolve/', views.AdminThreatResolveView.as_view(), name='threat-resolve'),
    path('security/stats/', views.AdminThreatStatsView.as_view(), name='security-stats'),
    path('security/anomalies/', views.AdminNetworkAnomalyListView.as_view(), name='anomaly-list'),

    # Notifications
    path('notifications/broadcast/', views.AdminBroadcastNotificationView.as_view(), name='broadcast-notification'),
    path('notifications/stats/', views.AdminNotificationStatsView.as_view(), name='notification-stats'),

    # Translations
    path('translations/stats/', views.AdminTranslationStatsView.as_view(), name='translation-stats'),

    # System
    path('system/info/', views.AdminSystemInfoView.as_view(), name='system-info'),
]
