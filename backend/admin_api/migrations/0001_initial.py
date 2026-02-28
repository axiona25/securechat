# Generated manually for AdminGroup and AdminGroupMembership

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='AdminGroup',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=255, unique=True)),
                ('description', models.TextField(blank=True, default='')),
                ('is_active', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'db_table': 'admin_groups',
                'ordering': ['-created_at'],
            },
        ),
        migrations.CreateModel(
            name='AdminGroupMembership',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('joined_at', models.DateTimeField(auto_now_add=True)),
                ('group', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='memberships', to='admin_api.admingroup')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='admin_group_memberships', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'admin_group_memberships',
                'unique_together': {('user', 'group')},
            },
        ),
        migrations.AddField(
            model_name='admingroup',
            name='members',
            field=models.ManyToManyField(blank=True, related_name='admin_groups', through='admin_api.AdminGroupMembership', to=settings.AUTH_USER_MODEL),
        ),
    ]
