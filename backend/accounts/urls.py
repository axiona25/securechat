from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView
from . import views

urlpatterns = [
    path('users/lookup/', views.UserLookupView.as_view(), name='user-lookup'),
    path('users/search/', views.search_users, name='user-search'),
    path('register/', views.RegisterView.as_view(), name='register'),
    path('verify-email/', views.VerifyEmailView.as_view(), name='verify-email'),
    path('resend-verification/', views.ResendVerificationView.as_view(), name='resend-verification'),
    path('login/', views.LoginView.as_view(), name='login'),
    path('logout/', views.LogoutView.as_view(), name='logout'),
    path('heartbeat/', views.heartbeat, name='heartbeat'),
    path('token/refresh/', TokenRefreshView.as_view(), name='token-refresh'),
    path('forgot-password/', views.ForgotPasswordView.as_view(), name='forgot-password'),
    path('reset-password/', views.ResetPasswordView.as_view(), name='reset-password'),
    path('profile/', views.ProfileView.as_view(), name='profile'),
    path('profile/notification-settings/', views.NotificationSettingsView.as_view(), name='profile-notification-settings'),
    path('avatar/', views.AvatarUploadView.as_view(), name='avatar-upload'),
    path('change-password/', views.ChangePasswordView.as_view(), name='change-password'),
    path('fcm-token/', views.FCMTokenView.as_view(), name='fcm-token'),
    path('apns-token/', views.ApnsTokenView.as_view(), name='apns-token'),
    path('voip-token/', views.VoipTokenView.as_view(), name='voip-token'),
    path('devices/register/', views.DeviceRegisterView.as_view(), name='device-register'),
    path('devices/', views.DeviceListView.as_view(), name='device-list'),
    path('devices/<str:device_id>/', views.DeviceDetailView.as_view(), name='device-detail'),
]
