from django.urls import path
from . import views

urlpatterns = [
    # Key management
    path('keys/upload/', views.UploadKeyBundleView.as_view(), name='upload-keys'),
    path('keys/<int:user_id>/', views.GetKeyBundleView.as_view(), name='get-keys'),
    path('keys/replenish/', views.ReplenishPreKeysView.as_view(), name='replenish-keys'),
    path('keys/rotate-signed/', views.RotateSignedPreKeyView.as_view(), name='rotate-signed-prekey'),
    path('keys/count/', views.PreKeyCountView.as_view(), name='prekey-count'),
    # Verification
    path('safety-number/<int:user_id>/', views.SafetyNumberView.as_view(), name='safety-number'),
    # Security
    path('security/alerts/', views.SecurityAlertsView.as_view(), name='security-alerts'),
]
