# Generated for VoIP PushKit token (iOS incoming calls in background)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0005_add_notifications_enabled'),
    ]

    operations = [
        migrations.AddField(
            model_name='user',
            name='voip_token',
            field=models.CharField(blank=True, max_length=255, null=True),
        ),
    ]
