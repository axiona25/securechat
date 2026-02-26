from django.apps import AppConfig


class ChannelsPubConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'channels_pub'
    verbose_name = 'Public Channels'

    def ready(self):
        import channels_pub.signals  # noqa: F401
