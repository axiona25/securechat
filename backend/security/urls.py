from django.urls import path
from . import views

urlpatterns = [
    path('scan/report/', views.SubmitScanReportView.as_view(), name='shield-scan-report'),
    path('ioc/update/', views.GetIOCUpdateView.as_view(), name='shield-ioc-update'),
    path('dashboard/', views.DeviceDashboardView.as_view(), name='shield-dashboard'),
    path('threats/<uuid:detection_id>/', views.ThreatDetailView.as_view(), name='shield-threat-detail'),
    path('threats/<uuid:detection_id>/resolve/', views.ResolveThreatView.as_view(), name='shield-threat-resolve'),
    path('emergency-lockdown/', views.EmergencyLockdownView.as_view(), name='shield-emergency-lockdown'),
]
