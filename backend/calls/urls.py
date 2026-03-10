from django.urls import path
from . import views

urlpatterns = [
    path('log/clear/', views.CallLogClearView.as_view(), name='call-log-clear'),
    path('log/', views.CallLogView.as_view(), name='call-log'),
    path('<uuid:call_id>/', views.CallDetailView.as_view(), name='call-detail'),
    path('ice-servers/', views.ICEServersView.as_view(), name='ice-servers'),
    path('missed-count/', views.MissedCallsCountView.as_view(), name='missed-count'),
]
