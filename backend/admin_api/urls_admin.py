from django.urls import path
from . import views
from . import e2e_views

urlpatterns = [
    path('stats/', views.AdminDashboardStatsView.as_view(), name='admin-stats'),
    path('users/', views.AdminUsersListView.as_view(), name='admin-users'),
    path('users/create/', views.AdminCreateUserView.as_view(), name='admin-create-user'),
    path('users/<int:user_id>/', views.AdminUpdateUserView.as_view(), name='admin-update-user'),
    path('users/<int:user_id>/reset-password/', views.AdminResetPasswordView.as_view(), name='admin-reset-password'),
    path('users/<int:user_id>/sync-groups/', views.AdminUserSyncGroupsView.as_view(), name='admin-sync-groups'),
    path('groups/', views.AdminGroupsListView.as_view(), name='admin-groups'),
    path('groups/<int:group_id>/', views.AdminGroupDetailView.as_view(), name='admin-group-detail'),
    path('groups/<int:group_id>/assign/', views.AdminGroupAssignUsersView.as_view(), name='admin-group-assign'),
    path('devices/', views.AdminDevicesListView.as_view(), name='admin-devices'),
    path('devices/<int:device_id>/', views.AdminDeviceDetailView.as_view(), name='admin-device-detail'),
    path('turn-logs/', views.AdminTurnLogsView.as_view(), name='admin-turn-logs'),
    path('settings/', views.AdminSettingsView.as_view(), name='admin-settings'),
    path('backup/', views.AdminBackupView.as_view(), name='admin-backup'),
    path('test-email/', views.AdminTestEmailView.as_view(), name='admin-test-email'),
    # E2E check endpoints (conversations, calls, key-bundles)
    path('conversations/', e2e_views.AdminPanelConversationsView.as_view(), name='admin-panel-conversations'),
    path('conversations/<uuid:conversation_id>/messages/', e2e_views.AdminPanelConversationMessagesView.as_view(), name='admin-panel-conversation-messages'),
    path('calls/', e2e_views.AdminPanelCallsView.as_view(), name='admin-panel-calls'),
    path('calls/<uuid:call_id>/', e2e_views.AdminPanelCallDetailView.as_view(), name='admin-panel-call-detail'),
    path('key-bundles/', e2e_views.AdminPanelKeyBundlesView.as_view(), name='admin-panel-key-bundles'),
    path('reset-e2e/', e2e_views.AdminResetE2EKeysView.as_view(), name='admin-reset-e2e'),
]
