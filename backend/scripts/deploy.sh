#!/bin/bash
# ──────────────────────────────────────────────────────
# SecureChat — Deploy script per DigitalOcean Droplet
# Esegui dal server: bash scripts/deploy.sh
# ──────────────────────────────────────────────────────
set -e

echo "══════════════════════════════════════════════"
echo "  SecureChat Deploy — DigitalOcean"
echo "══════════════════════════════════════════════"

PROJECT_DIR="/opt/securechat"
cd "$PROJECT_DIR"

# 1. Pull latest code
echo "[1/8] Pulling latest code..."
git pull origin main

# 2. Activate virtualenv
echo "[2/8] Activating virtualenv..."
source venv/bin/activate

# 3. Install dependencies
echo "[3/8] Installing dependencies..."
pip install -r requirements.txt --quiet

# 4. Run migrations
echo "[4/8] Running migrations..."
python manage.py migrate --noinput

# 5. Collect static files (to DO Spaces if USE_SPACES=True)
echo "[5/8] Collecting static files..."
python manage.py collectstatic --noinput

# 6. Restart Daphne (ASGI server)
echo "[6/8] Restarting Daphne..."
sudo supervisorctl restart securechat-daphne

# 7. Restart Celery workers
echo "[7/8] Restarting Celery..."
sudo supervisorctl restart securechat-celery-worker
sudo supervisorctl restart securechat-celery-beat

# 8. Reload Nginx
echo "[8/8] Reloading Nginx..."
sudo nginx -t && sudo systemctl reload nginx

echo ""
echo "✅ Deploy completato!"
echo "══════════════════════════════════════════════"
