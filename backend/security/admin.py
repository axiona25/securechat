from django.contrib import admin
from .models import (
    ThreatIndicator, DeviceSecurityProfile, ThreatDetection,
    NetworkAnomalyLog, IOCDatabaseVersion
)


@admin.register(ThreatIndicator)
class ThreatIndicatorAdmin(admin.ModelAdmin):
    list_display = ['ioc_type', 'value_short', 'spyware_family', 'severity', 'platform', 'is_active', 'true_positive_count', 'false_positive_count']
    list_filter = ['ioc_type', 'spyware_family', 'severity', 'platform', 'is_active']
    search_fields = ['value', 'description']
    readonly_fields = ['true_positive_count', 'false_positive_count']

    def value_short(self, obj):
        return obj.value[:80] + '...' if len(obj.value) > 80 else obj.value
    value_short.short_description = 'Value'


@admin.register(DeviceSecurityProfile)
class DeviceSecurityProfileAdmin(admin.ModelAdmin):
    list_display = ['user', 'device_model', 'os_type', 'os_version', 'risk_level', 'is_rooted', 'threat_count', 'last_scan_at']
    list_filter = ['risk_level', 'os_type', 'is_rooted', 'has_hooking_frameworks']
    search_fields = ['user__email', 'device_model', 'device_id']


@admin.register(ThreatDetection)
class ThreatDetectionAdmin(admin.ModelAdmin):
    list_display = ['user', 'detection_type', 'severity', 'status', 'scan_type', 'detected_at']
    list_filter = ['detection_type', 'severity', 'status', 'scan_type']
    search_fields = ['user__email', 'detection_detail', 'matched_value']
    readonly_fields = ['raw_evidence']


@admin.register(NetworkAnomalyLog)
class NetworkAnomalyLogAdmin(admin.ModelAdmin):
    list_display = ['user', 'destination_domain', 'destination_ip', 'destination_port', 'is_suspicious', 'detected_at']
    list_filter = ['is_suspicious']
    search_fields = ['destination_domain', 'destination_ip', 'suspicion_reason']


@admin.register(IOCDatabaseVersion)
class IOCDatabaseVersionAdmin(admin.ModelAdmin):
    list_display = ['version', 'ioc_count', 'is_current', 'published_at']
    list_filter = ['is_current']
