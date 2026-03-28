from django.db import migrations, models
from django.db.models import F


def copy_device_id_to_imei(apps, schema_editor):
    UserDevice = apps.get_model('accounts', 'UserDevice')
    UserDevice.objects.all().update(imei=F('device_id'))


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0008_user_apns_token_userdevice_app_version'),
    ]

    operations = [
        migrations.AlterUniqueTogether(
            name='userdevice',
            unique_together=set(),
        ),
        migrations.AddField(
            model_name='userdevice',
            name='imei',
            field=models.CharField(default='', max_length=255),
        ),
        migrations.RunPython(copy_device_id_to_imei, migrations.RunPython.noop),
        migrations.AlterField(
            model_name='userdevice',
            name='device_id',
            field=models.CharField(blank=True, default='', help_text='Etichetta secondaria / legacy; la deduplicazione è su user+imei.', max_length=255),
        ),
        migrations.AlterUniqueTogether(
            name='userdevice',
            unique_together={('user', 'imei')},
        ),
    ]
