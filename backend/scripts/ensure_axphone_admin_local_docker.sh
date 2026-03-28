#!/usr/bin/env bash
# Crea/aggiorna admin@axphone.it usando MySQL in Docker (Compose) su localhost.
# Prerequisiti:
#   1) cd repo && docker compose up -d db
#   2) venv in backend: pyenv/3.12+ → python3 -m venv venv && pip install -r requirements.txt
#   3) backend/.env → symlink a ../.env (o copia con DB_* coerenti)
#
# Uso:
#   export AXPHONE_ADMIN_PASSWORD='la-password'
#   ./scripts/ensure_axphone_admin_local_docker.sh
#
# Override porta host (default 3307 come in docker-compose.yml):
#   LOCAL_DB_PORT=3307 ./scripts/ensure_axphone_admin_local_docker.sh

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${AXPHONE_ADMIN_PASSWORD:-}" ]]; then
  echo "Imposta AXPHONE_ADMIN_PASSWORD (es. export AXPHONE_ADMIN_PASSWORD='...')" >&2
  exit 1
fi

export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${LOCAL_DB_PORT:-${DB_PORT:-3307}}"

if [[ ! -x ./venv/bin/python ]]; then
  echo "Manca backend/venv. Esempio: $(pyenv root 2>/dev/null)/versions/3.12.4/bin/python3 -m venv venv && ./venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi

echo "Using DB ${DB_HOST}:${DB_PORT} (override per Docker locale; ignora host 'db' del .env)"
exec ./venv/bin/python manage.py ensure_axphone_admin
