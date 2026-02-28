from django.urls import path
from . import views

urlpatterns = [
    path('stats/', views.AdminDashboardStatsView.as_view(), name='admin-stats'),
    path('users/', views.AdminUsersListView.as_view(), name='admin-users'),
    path('users/create/', views.AdminCreateUserView.as_view(), name='admin-create-user'),
    path('users/<int:user_id>/', views.AdminUpdateUserView.as_view(), name='admin-update-user'),
    path('users/<int:user_id>/reset-password/', views.AdminResetPasswordView.as_view(), name='admin-reset-password'),
    path('groups/', views.AdminGroupsListView.as_view(), name='admin-groups'),
    path('groups/<int:group_id>/', views.AdminGroupDetailView.as_view(), name='admin-group-detail'),
    path('groups/<int:group_id>/assign/', views.AdminGroupAssignUsersView.as_view(), name='admin-group-assign'),
]
