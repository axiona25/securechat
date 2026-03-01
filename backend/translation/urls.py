from django.urls import path
from . import views

urlpatterns = [
    path('translate/', views.TranslateMessageView.as_view(), name='translate-message'),
    path('translate/batch/', views.TranslateBatchView.as_view(), name='translate-batch'),
    path('languages/', views.available_languages, name='translation-languages'),
    path('check/', views.check_translation_available, name='check-translation'),
]
