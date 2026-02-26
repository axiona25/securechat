from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('chat', '0003_rename_messages_convers_created_idx_messages_convers_3ebb41_idx_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='conversationparticipant',
            name='cleared_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
