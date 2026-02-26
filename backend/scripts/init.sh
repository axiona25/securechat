#!/bin/bash
set -e

echo "Waiting for database..."
python manage.py wait_for_db 2>/dev/null || sleep 5

echo "Running migrations..."
python manage.py makemigrations --noinput
python manage.py migrate --noinput

echo "Collecting static files..."
python manage.py collectstatic --noinput

echo "Creating superuser..."
python manage.py createsuperuser --noinput 2>/dev/null || echo "Superuser already exists"

echo "Init complete!"
