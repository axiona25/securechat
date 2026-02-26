#!/usr/bin/env python
"""
Health check script per verificare che tutti i servizi siano operativi.
Usato dal monitoring DO e dal deploy script.
Esegui: python scripts/healthcheck.py
"""
import os
import sys
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.base')
django.setup()

from django.db import connection
from django.core.cache import cache


def check_database():
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
        return True, "MySQL OK"
    except Exception as e:
        return False, f"MySQL FAIL: {e}"


def check_redis():
    try:
        cache.set('healthcheck', 'ok', 10)
        result = cache.get('healthcheck')
        if result == 'ok':
            return True, "Redis OK"
        return False, "Redis FAIL: cache read mismatch"
    except Exception as e:
        return False, f"Redis FAIL: {e}"


def check_celery():
    try:
        from celery import current_app
        inspector = current_app.control.inspect(timeout=3.0)
        active = inspector.active()
        if active:
            worker_count = len(active)
            return True, f"Celery OK ({worker_count} workers)"
        return False, "Celery FAIL: no active workers"
    except Exception as e:
        return False, f"Celery FAIL: {e}"


def main():
    print("SecureChat Health Check")
    print("=" * 40)

    all_ok = True
    checks = [
        ("Database", check_database),
        ("Redis", check_redis),
        ("Celery", check_celery),
    ]

    for name, check_fn in checks:
        ok, msg = check_fn()
        status = "✅" if ok else "❌"
        print(f"  {status} {name}: {msg}")
        if not ok:
            all_ok = False

    print("=" * 40)
    if all_ok:
        print("All checks passed ✅")
        sys.exit(0)
    else:
        print("Some checks failed ❌")
        sys.exit(1)


if __name__ == '__main__':
    main()
