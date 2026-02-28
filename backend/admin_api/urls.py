from django.urls import path, include

app_name = 'admin_api'

# Admin panel API (stats, users, groups) - same routes as urls_admin for backward compatibility
urlpatterns = [
    path('', include('admin_api.urls_admin')),
]
