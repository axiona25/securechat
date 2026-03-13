from django.urls import path
from . import views

urlpatterns = [
    # Hard reset E2E (test/recovery: clear server bundle for current user)
    path('reset/', views.E2EResetView.as_view(), name='e2e-reset'),
    # Encrypted key backup (client-encrypted blob only)
    path('backup/', views.E2EKeyBackupView.as_view(), name='e2e-backup'),
    # Key management
    path('keys/reset-otp/', views.ResetOtpView.as_view(), name='reset-otp'),
    path('keys/upload/', views.UploadKeyBundleView.as_view(), name='upload-keys'),
    path('keys/me/', views.MyKeyBundleMetaView.as_view(), name='my-key-bundle-meta'),
    path('keys/<int:user_id>/', views.GetKeyBundleView.as_view(), name='get-keys'),
    path('keys/replenish/', views.ReplenishPreKeysView.as_view(), name='replenish-keys'),
    path('keys/rotate-signed/', views.RotateSignedPreKeyView.as_view(), name='rotate-signed-prekey'),
    path('keys/count/', views.PreKeyCountView.as_view(), name='prekey-count'),
    # Verification
    path('safety-number/<int:user_id>/', views.SafetyNumberView.as_view(), name='safety-number'),
    # Security
    path('security/alerts/', views.SecurityAlertsView.as_view(), name='security-alerts'),
]
