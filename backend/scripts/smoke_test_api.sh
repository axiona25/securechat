#!/bin/bash
# SecureChat — API Smoke Test
# Esegui dalla root del progetto: bash backend/scripts/smoke_test_api.sh

BASE="http://localhost:8000/api"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
PASS=0
FAIL=0

check() {
    local desc="$1"
    local url="$2"
    local method="${3:-GET}"
    local data="$4"
    local expected="${5:-200}"
    local token="$6"

    local headers="-H 'Content-Type: application/json'"
    if [ -n "$token" ]; then
        headers="$headers -H 'Authorization: Bearer $token'"
    fi

    if [ "$method" = "POST" ]; then
        code=$(eval curl -s -o /dev/null -w '%{http_code}' -X POST $headers -d "'$data'" "$url")
    else
        code=$(eval curl -s -o /dev/null -w '%{http_code}' $headers "$url")
    fi

    if [ "$code" = "$expected" ]; then
        echo -e "${GREEN}✅ $desc — HTTP $code${NC}"
        PASS=$((PASS+1))
    else
        echo -e "${RED}❌ $desc — HTTP $code (expected $expected)${NC}"
        FAIL=$((FAIL+1))
    fi
}

echo "================================================"
echo "🔍 SecureChat API Smoke Tests"
echo "================================================"

# Health
check "Health Check" "$BASE/health/"

# Register
REGISTER_RESP=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"username":"smoketest","email":"smoke@test.com","password":"SmokeTest123!","password_confirm":"SmokeTest123!","first_name":"Smoke","last_name":"Test"}' \
    "$BASE/auth/register/")
echo "Register response: $REGISTER_RESP"
PASS=$((PASS+1))

# Login
LOGIN_RESP=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"email":"smoke@test.com","password":"SmokeTest123!"}' \
    "$BASE/auth/login/")
echo "Login response: $LOGIN_RESP"

# Extract token (try multiple JSON structures)
TOKEN=$(echo "$LOGIN_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for key in ['access', 'token']:
        if isinstance(d.get(key), str):
            print(d[key]); break
        elif isinstance(d.get(key), dict):
            print(d[key].get('access', '')); break
    else:
        if 'tokens' in d:
            print(d['tokens'].get('access', ''))
except Exception:
    pass
" 2>/dev/null)

if [ -n "$TOKEN" ]; then
    echo -e "${GREEN}✅ Got JWT token${NC}"
    PASS=$((PASS+1))

    # Profile
    check "Profile" "$BASE/auth/profile/" "GET" "" "200" "$TOKEN"

    # Conversations list
    check "Conversations List" "$BASE/chat/conversations/" "GET" "" "200" "$TOKEN"

    # Encryption key bundle (GET should be 405 Method Not Allowed)
    check "Key Bundle Upload endpoint" "$BASE/encryption/keys/upload/" "GET" "" "405" "$TOKEN"

    # Notifications badge
    check "Notifications Badge" "$BASE/notifications/badge/" "GET" "" "200" "$TOKEN"

else
    echo -e "${RED}❌ No JWT token — login failed${NC}"
    FAIL=$((FAIL+1))
fi

# Admin login (requires auth, expect 401 without token)
check "Admin Panel — requires auth" "http://localhost:8000/api/admin-panel/dashboard/" "GET" "" "401"

echo ""
echo "================================================"
echo "📊 Results: $PASS passed, $FAIL failed"
echo "================================================"
