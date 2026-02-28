# Generated manually for approval_status and must_change_password

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0003_add_fcm_token'),
    ]

    operations = [
        migrations.AddField(
            model_name='user',
            name='approval_status',
            field=models.CharField(
                choices=[('approved', 'Approvato'), ('pending', 'Da approvare'), ('blocked', 'Bloccato')],
                default='pending',
                max_length=20,
            ),
        ),
        migrations.AddField(
            model_name='user',
            name='must_change_password',
            field=models.BooleanField(default=False),
        ),
    ]
