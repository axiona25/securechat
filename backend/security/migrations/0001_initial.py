import uuid
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
            name='ThreatIndicator',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('ioc_type', models.CharField(choices=[('domain', 'Malicious Domain'), ('ip', 'Malicious IP Address'), ('process', 'Suspicious Process Name'), ('file_path', 'Suspicious File Path'), ('file_hash', 'Malicious File Hash'), ('certificate', 'Suspicious SSL Certificate'), ('package', 'Malicious Package/App'), ('behavior', 'Behavioral Pattern'), ('network_pattern', 'Network Traffic Pattern'), ('dns', 'Suspicious DNS Query')], max_length=20)),
                ('value', models.TextField(help_text='The actual IOC value (domain, IP, hash, path, etc.)')),
                ('spyware_family', models.CharField(choices=[('pegasus', 'NSO Group Pegasus'), ('predator', 'Cytrox/Intellexa Predator'), ('hermit', 'RCS Lab Hermit'), ('candiru', 'Candiru DevilsTongue'), ('finspy', 'FinFisher FinSpy'), ('quadream', 'QuaDream Reign'), ('cytrox', 'Cytrox'), ('unknown', 'Unknown/Generic'), ('custom', 'Custom/Research')], default='unknown', max_length=20)),
                ('severity', models.IntegerField(choices=[(1, 'Informational'), (2, 'Low'), (3, 'Medium'), (4, 'High'), (5, 'Critical - Confirmed Spyware')], default=3)),
                ('platform', models.CharField(choices=[('ios', 'iOS'), ('android', 'Android'), ('both', 'iOS & Android'), ('windows', 'Windows'), ('macos', 'macOS'), ('all', 'All Platforms')], default='both', max_length=10)),
                ('description', models.TextField(blank=True, default='')),
                ('source', models.CharField(blank=True, default='', help_text='Where this IOC came from (e.g., Amnesty MVT, Citizen Lab, internal)', max_length=200)),
                ('first_seen', models.DateTimeField(blank=True, null=True)),
                ('last_seen', models.DateTimeField(blank=True, null=True)),
                ('is_active', models.BooleanField(default=True)),
                ('false_positive_count', models.IntegerField(default=0)),
                ('true_positive_count', models.IntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'db_table': 'threat_indicators',
                'ordering': ['-severity', '-updated_at'],
            },
        ),
        migrations.AddIndex(
            model_name='threatindicator',
            index=models.Index(fields=['ioc_type', 'is_active'], name='threat_indi_ioc_typ_idx'),
        ),
        migrations.AddIndex(
            model_name='threatindicator',
            index=models.Index(fields=['spyware_family'], name='threat_indi_family_idx'),
        ),
        migrations.AddIndex(
            model_name='threatindicator',
            index=models.Index(fields=['platform'], name='threat_indi_platform_idx'),
        ),
        migrations.CreateModel(
            name='IOCDatabaseVersion',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('version', models.CharField(max_length=50, unique=True)),
                ('ioc_count', models.IntegerField(default=0)),
                ('changelog', models.TextField(blank=True, default='')),
                ('published_at', models.DateTimeField(auto_now_add=True)),
                ('is_current', models.BooleanField(default=False)),
            ],
            options={
                'db_table': 'ioc_database_versions',
                'ordering': ['-published_at'],
            },
        ),
        migrations.CreateModel(
            name='DeviceSecurityProfile',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('device_id', models.CharField(help_text='Unique device identifier', max_length=200)),
                ('device_model', models.CharField(blank=True, default='', max_length=100)),
                ('os_type', models.CharField(choices=[('ios', 'iOS'), ('android', 'Android'), ('desktop', 'Desktop')], max_length=10)),
                ('os_version', models.CharField(blank=True, default='', max_length=50)),
                ('app_version', models.CharField(blank=True, default='', max_length=20)),
                ('risk_level', models.CharField(choices=[('safe', 'Safe'), ('low', 'Low Risk'), ('medium', 'Medium Risk'), ('high', 'High Risk'), ('critical', 'Critical - Possible Compromise'), ('compromised', 'Confirmed Compromise')], default='safe', max_length=15)),
                ('is_rooted', models.BooleanField(default=False)),
                ('is_debugger_attached', models.BooleanField(default=False)),
                ('has_hooking_frameworks', models.BooleanField(default=False)),
                ('has_suspicious_apps', models.BooleanField(default=False)),
                ('has_network_anomalies', models.BooleanField(default=False)),
                ('code_integrity_valid', models.BooleanField(default=True)),
                ('certificate_pinning_valid', models.BooleanField(default=True)),
                ('secure_enclave_available', models.BooleanField(default=True)),
                ('last_scan_at', models.DateTimeField(blank=True, null=True)),
                ('last_ioc_version', models.CharField(blank=True, default='', help_text='Last IOC database version synced', max_length=50)),
                ('scan_count', models.IntegerField(default=0)),
                ('threat_count', models.IntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='device_profiles', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'device_security_profiles',
                'unique_together': {('user', 'device_id')},
            },
        ),
        migrations.CreateModel(
            name='ThreatDetection',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('detection_type', models.CharField(max_length=50)),
                ('detection_detail', models.TextField(help_text='What exactly was found')),
                ('matched_value', models.TextField(blank=True, default='', help_text='The value that matched the IOC')),
                ('severity', models.IntegerField(default=3)),
                ('status', models.CharField(choices=[('detected', 'Detected'), ('investigating', 'Under Investigation'), ('confirmed', 'Confirmed Threat'), ('false_positive', 'False Positive'), ('resolved', 'Resolved'), ('ignored', 'Ignored by User')], default='detected', max_length=15)),
                ('scan_type', models.CharField(choices=[('startup', 'App Startup Scan'), ('periodic', 'Periodic Scan'), ('manual', 'User-Initiated Scan'), ('realtime', 'Real-Time Detection'), ('network', 'Network Monitoring')], default='periodic', max_length=20)),
                ('raw_evidence', models.JSONField(blank=True, default=dict, help_text='Raw data supporting the detection')),
                ('detected_at', models.DateTimeField(auto_now_add=True)),
                ('resolved_at', models.DateTimeField(blank=True, null=True)),
                ('user_notified', models.BooleanField(default=False)),
                ('user_notified_at', models.DateTimeField(blank=True, null=True)),
                ('device', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='detections', to='security.devicesecurityprofile')),
                ('threat_indicator', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='detections', to='security.threatindicator')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='threat_detections', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'threat_detections',
                'ordering': ['-detected_at'],
            },
        ),
        migrations.CreateModel(
            name='NetworkAnomalyLog',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('destination_ip', models.GenericIPAddressField(blank=True, null=True)),
                ('destination_domain', models.CharField(blank=True, default='', max_length=300)),
                ('destination_port', models.IntegerField(blank=True, null=True)),
                ('protocol', models.CharField(default='tcp', max_length=10)),
                ('bytes_sent', models.BigIntegerField(default=0)),
                ('bytes_received', models.BigIntegerField(default=0)),
                ('connection_duration', models.FloatField(blank=True, help_text='Duration in seconds', null=True)),
                ('is_suspicious', models.BooleanField(default=False)),
                ('suspicion_reason', models.TextField(blank=True, default='')),
                ('detected_at', models.DateTimeField(auto_now_add=True)),
                ('device', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='network_anomalies', to='security.devicesecurityprofile')),
                ('matched_ioc', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, to='security.threatindicator')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='network_anomalies', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'db_table': 'network_anomaly_logs',
                'ordering': ['-detected_at'],
            },
        ),
    ]
