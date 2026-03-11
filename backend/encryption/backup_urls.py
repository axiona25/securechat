"""URLs for E2E key backup API (exposed under api/crypto/ as requested)."""
from django.urls import path
from . import views

urlpatterns = [
    path('backup/', views.E2EKeyBackupView.as_view(), name='e2e-backup'),
]
