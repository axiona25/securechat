"""
SecureChat Shield - Known IOC Database Seed
============================================
Sources:
- Amnesty International MVT indicators
- Citizen Lab research publications
- Google Threat Analysis Group (TAG) reports
- Lookout threat intelligence
- Internal research

This is the initial seed. The system is designed to receive
updates via the admin panel or automated feeds.

IMPORTANT: These IOCs change frequently. This seed provides
a baseline; the admin team must keep them updated.
"""


def get_initial_iocs():
    """
    Returns the initial set of IOCs to seed the database.
    Based on publicly available research as of early 2026.
    """
    iocs = []

    # ═══════════════════════════════════════════
    # PEGASUS (NSO Group) - Known Infrastructure
    # Source: Amnesty International, Citizen Lab
    # ═══════════════════════════════════════════

    pegasus_domains = [
        'amazonaws.com.researchdata.wiki',
        'apple-ede.org',
        'apple-health.org',
        'apple-icloud.net',
        'apple-mapkit.com',
        'cdn-icloud.net',
        'cloudapps-storage.net',
        'documentss-storage.com',
        'federation-id.com',
        'free-ede.net',
        'icloud-services.net',
        'icloud-verification.net',
        'icloud-verify.com',
        'infoservices-apple.com',
        'manag-ede.net',
        'maptools-service.com',
        'multimedia-ede.org',
        'news-ede.net',
        'notification-ede.net',
        'pcsinspection.com',
        'revolution-ede.net',
        'safari-ede.net',
        'service-ede.net',
        'storage-icloud.net',
        'verifyapp-id.com',
    ]
    for domain in pegasus_domains:
        iocs.append({
            'ioc_type': 'domain',
            'value': domain,
            'spyware_family': 'pegasus',
            'severity': 5,
            'platform': 'both',
            'description': 'Known Pegasus C2 infrastructure domain. Connection to this domain indicates probable Pegasus infection.',
            'source': 'Amnesty International MVT / Citizen Lab',
        })

    # Pegasus process names (iOS)
    pegasus_processes = [
        'bh', 'roleaboutd', 'pcaborede', 'iconlocked',
        'liaborede', 'natgd', 'setframed', 'fservernetd',
        'ABSCarrier', 'BoardSwitchd', 'CommsCenterRootH',
        'JarvisPluginMgr', 'laaborede', 'RollingStoraged',
    ]
    for proc in pegasus_processes:
        iocs.append({
            'ioc_type': 'process',
            'value': proc,
            'spyware_family': 'pegasus',
            'severity': 5,
            'platform': 'ios',
            'description': f'Pegasus spyware process name "{proc}" found in Amnesty International analysis.',
            'source': 'Amnesty International MVT',
        })

    # Pegasus file paths (iOS)
    pegasus_paths = [
        '/private/var/db/com.apple.xpc.roleaccountd.staging/',
        '/private/var/tmp/BridgeHead/',
        '/private/var/tmp/Crumble/',
        '/private/var/tmp/Lemongrass/',
    ]
    for path in pegasus_paths:
        iocs.append({
            'ioc_type': 'file_path',
            'value': path,
            'spyware_family': 'pegasus',
            'severity': 5,
            'platform': 'ios',
            'description': f'File system path associated with Pegasus staging directory.',
            'source': 'Amnesty International MVT',
        })

    # ═══════════════════════════════════════════
    # PREDATOR (Cytrox/Intellexa)
    # Source: Citizen Lab, Google TAG
    # ═══════════════════════════════════════════

    predator_domains = [
        'loginstyle.com',
        'redirect-ede.net',
        'webanalytics-ede.com',
        'tracker-analytics.net',
        'sec-flare.com',
        'cdn-analytics.org',
    ]
    for domain in predator_domains:
        iocs.append({
            'ioc_type': 'domain',
            'value': domain,
            'spyware_family': 'predator',
            'severity': 5,
            'platform': 'both',
            'description': 'Known Predator spyware C2 domain.',
            'source': 'Citizen Lab / Google TAG',
        })

    # ═══════════════════════════════════════════
    # HERMIT (RCS Lab)
    # Source: Lookout, Google TAG
    # ═══════════════════════════════════════════

    hermit_packages = [
        'com.app.opssa',
        'com.session.helper',
        'com.lte.carrier',
        'it.servizipubblici.app',
    ]
    for pkg in hermit_packages:
        iocs.append({
            'ioc_type': 'package',
            'value': pkg,
            'spyware_family': 'hermit',
            'severity': 5,
            'platform': 'android',
            'description': f'Android package name associated with Hermit spyware.',
            'source': 'Lookout / Google TAG',
        })

    # ═══════════════════════════════════════════
    # GENERIC INDICATORS
    # Root/Jailbreak detection, hooking frameworks
    # ═══════════════════════════════════════════

    # Root indicators (Android)
    root_indicators = [
        ('file_path', '/system/app/Superuser.apk', 'android'),
        ('file_path', '/system/xbin/su', 'android'),
        ('file_path', '/system/bin/su', 'android'),
        ('file_path', '/data/local/su', 'android'),
        ('file_path', '/data/local/bin/su', 'android'),
        ('file_path', '/sbin/su', 'android'),
        ('package', 'com.topjohnwu.magisk', 'android'),
        ('package', 'eu.chainfire.supersu', 'android'),
        ('package', 'com.koushikdutta.superuser', 'android'),
        ('package', 'com.noshufou.android.su', 'android'),
        ('package', 'com.thirdparty.superuser', 'android'),
        ('package', 'com.yellowes.su', 'android'),
    ]
    for ioc_type, value, platform in root_indicators:
        iocs.append({
            'ioc_type': ioc_type,
            'value': value,
            'spyware_family': 'unknown',
            'severity': 3,
            'platform': platform,
            'description': f'Root/Superuser indicator: {value}. Rooted devices are more vulnerable to spyware.',
            'source': 'Internal research',
        })

    # Jailbreak indicators (iOS)
    jailbreak_indicators = [
        '/Applications/Cydia.app',
        '/Library/MobileSubstrate/MobileSubstrate.dylib',
        '/var/cache/apt',
        '/var/lib/apt',
        '/usr/sbin/sshd',
        '/etc/apt',
        '/usr/bin/ssh',
        '/private/var/lib/apt/',
        '/Applications/SBSettings.app',
        '/private/var/stash',
        '/usr/libexec/sftp-server',
    ]
    for path in jailbreak_indicators:
        iocs.append({
            'ioc_type': 'file_path',
            'value': path,
            'spyware_family': 'unknown',
            'severity': 3,
            'platform': 'ios',
            'description': f'Jailbreak indicator: {path}. Jailbroken devices are more vulnerable to spyware.',
            'source': 'Internal research',
        })

    # Hooking frameworks
    hooking_indicators = [
        ('package', 'de.robv.android.xposed.installer', 'android', 'Xposed Framework'),
        ('package', 'com.saurik.substrate', 'android', 'Cydia Substrate (Android)'),
        ('process', 'frida-server', 'both', 'Frida dynamic instrumentation toolkit'),
        ('process', 'frida-agent', 'both', 'Frida agent process'),
        ('file_path', '/data/local/tmp/frida-server', 'android', 'Frida server binary'),
        ('file_path', '/usr/lib/frida/', 'ios', 'Frida library path'),
        ('process', 'objection', 'both', 'Objection runtime exploration'),
        ('file_path', '/usr/lib/libcycript.dylib', 'ios', 'Cycript dynamic analysis'),
    ]
    for ioc_type, value, platform, desc in hooking_indicators:
        iocs.append({
            'ioc_type': ioc_type,
            'value': value,
            'spyware_family': 'unknown',
            'severity': 4,
            'platform': platform,
            'description': f'Hooking/instrumentation framework detected: {desc}. '
                          f'May indicate active tampering or spyware injection.',
            'source': 'Internal research',
        })

    # Suspicious network patterns
    network_patterns = [
        {
            'ioc_type': 'behavior',
            'value': 'mic_active_screen_off',
            'severity': 5,
            'description': 'Microphone active while screen is off and no call in progress. '
                          'Strong indicator of audio surveillance spyware.',
        },
        {
            'ioc_type': 'behavior',
            'value': 'camera_active_screen_off',
            'severity': 5,
            'description': 'Camera active while screen is off. '
                          'Strong indicator of visual surveillance spyware.',
        },
        {
            'ioc_type': 'behavior',
            'value': 'excessive_data_upload_background',
            'severity': 4,
            'description': 'Large data uploads occurring in background without user activity. '
                          'May indicate data exfiltration by spyware.',
        },
        {
            'ioc_type': 'behavior',
            'value': 'unknown_accessibility_service',
            'severity': 4,
            'description': 'Unknown accessibility service active. Spyware often abuses '
                          'accessibility permissions to capture screen content and keystrokes.',
        },
        {
            'ioc_type': 'behavior',
            'value': 'ssl_proxy_detected',
            'severity': 4,
            'description': 'SSL/TLS interception proxy detected. Someone may be intercepting '
                          'encrypted traffic via a rogue CA certificate.',
        },
        {
            'ioc_type': 'behavior',
            'value': 'device_admin_unknown',
            'severity': 4,
            'description': 'Unknown device administrator active on Android. Spyware uses '
                          'device admin to prevent uninstallation.',
        },
    ]
    for pattern in network_patterns:
        pattern.setdefault('spyware_family', 'unknown')
        pattern.setdefault('platform', 'both')
        pattern.setdefault('source', 'Internal research')
        iocs.append(pattern)

    return iocs
