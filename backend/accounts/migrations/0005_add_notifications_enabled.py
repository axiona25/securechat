# Generated for notifications_enabled (push notification toggle)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0004_approval_status_and_must_change_password'),
    ]

    operations = [
        migrations.AddField(
            model_name='user',
            name='notifications_enabled',
            field=models.BooleanField(default=True),
        ),
    ]
