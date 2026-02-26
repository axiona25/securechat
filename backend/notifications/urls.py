from django.urls import path
from . import views

app_name = 'notifications'

urlpatterns = [
    # Device token management
    path('devices/', views.MyDevicesView.as_view(), name='my-devices'),
    path('devices/register/', views.RegisterDeviceTokenView.as_view(), name='register-device'),
    path('devices/unregister/', views.UnregisterDeviceTokenView.as_view(), name='unregister-device'),

    # Preferences
    path('preferences/', views.NotificationPreferencesView.as_view(), name='preferences'),

    # Mute rules
    path('mute/', views.MuteRuleListCreateView.as_view(), name='mute-list-create'),
    path('mute/<str:target_type>/<str:target_id>/', views.MuteRuleDeleteView.as_view(), name='mute-delete'),

    # Notification history — put literal paths before uuid paths
    path('', views.NotificationListView.as_view(), name='notification-list'),
    path('read-all/', views.NotificationMarkAllReadView.as_view(), name='mark-all-read'),
    path('clear/', views.NotificationClearAllView.as_view(), name='clear-all'),
    path('<uuid:notification_id>/read/', views.NotificationMarkReadView.as_view(), name='mark-read'),
    path('<uuid:notification_id>/delete/', views.NotificationDeleteView.as_view(), name='notification-delete'),

    # Badge count
    path('badge/', views.BadgeCountView.as_view(), name='badge-count'),
]
