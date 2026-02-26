from django.urls import path
from . import views

app_name = 'translation'

urlpatterns = [
    # Preferences
    path('preferences/', views.TranslationPreferenceView.as_view(), name='preferences'),

    # Per-conversation settings
    path('conversations/', views.ConversationTranslationSettingView.as_view(), name='conversation-settings'),
    path('conversations/<uuid:conversation_id>/', views.ConversationTranslationSettingDeleteView.as_view(), name='conversation-setting-delete'),

    # Translation
    path('translate/message/', views.TranslateMessageView.as_view(), name='translate-message'),
    path('translate/text/', views.TranslateTextView.as_view(), name='translate-text'),
    path('translate/batch/', views.TranslateBatchView.as_view(), name='translate-batch'),

    # Language detection
    path('detect/', views.DetectLanguageView.as_view(), name='detect-language'),

    # Languages info
    path('languages/', views.InstalledLanguagesView.as_view(), name='installed-languages'),
    path('languages/pairs/', views.InstalledPairsView.as_view(), name='installed-pairs'),
    path('languages/check/', views.CheckPairView.as_view(), name='check-pair'),

    # Language pack management (admin)
    path('packages/available/', views.AvailablePackagesView.as_view(), name='available-packages'),
    path('packages/installed/', views.InstalledPackagesView.as_view(), name='installed-packages'),
    path('packages/install/', views.InstallPackageView.as_view(), name='install-package'),

    # Stats
    path('stats/', views.TranslationStatsView.as_view(), name='admin-stats'),
    path('stats/me/', views.MyTranslationStatsView.as_view(), name='my-stats'),
]
