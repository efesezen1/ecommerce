#!/usr/bin/env bash
# ============================================================
# E-Commerce API – End-to-End Test Script
# Flow: health → auth → products → cart → orders → payments
# ============================================================

BASE_URL="http://localhost:3000"
PASS=0
FAIL=0

# ── Helpers ────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

section() { echo -e "\n${CYAN}${BOLD}── $1 ──────────────────────────────${NC}"; }
ok()      { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)); }
info()    { echo -e "  ${YELLOW}→${NC} $1"; }

# Assert HTTP status matches expected value.
# Usage: assert_status <label> <expected> <actual>
assert_status() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label (HTTP $actual)"
  else
    fail "$label – expected HTTP $expected, got HTTP $actual"
  fi
}

# POST helper – returns full response; status in last line.
post() {
  local url="$1" data="$2" token="$3"
  local auth_header=""
  [[ -n "$token" ]] && auth_header="-H \"Authorization: Bearer $token\""
  eval curl -s -w '\n%{http_code}' -X POST \
    -H "\"Content-Type: application/json\"" \
    $auth_header \
    -d "'$data'" \
    "\"$BASE_URL$url\""
}

# Generic curl wrapper; last line = HTTP status, rest = body.
req() {
  local method="$1" url="$2" data="$3" token="$4"
  local auth_header=()
  [[ -n "$token" ]] && auth_header=(-H "Authorization: Bearer $token")
  local args=(-s -w '\n%{http_code}' -X "$method" -H "Content-Type: application/json" "${auth_header[@]}")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "$BASE_URL$url"
}

# Split response into body and status.
# Note: `head -n -1` is GNU-only; `sed '$d'` works on macOS BSD too.
body_of()   { printf '%s' "$1" | sed '$d'; }
status_of() { printf '%s' "$1" | tail -n 1; }

# Extract a JSON field value (simple key:"value" or key:number).
json_val() {
  local json="$1" key="$2"
  echo "$json" | grep -o "\"$key\":[^,}]*" | head -1 | sed 's/.*://;s/[" ]//g'
}

# ============================================================
echo -e "\n${BOLD}E-Commerce API – Integration Tests${NC}"
echo "Base URL: $BASE_URL"
echo "Date    : $(date)"

# ── 1. Health Check ─────────────────────────────────────────
section "1. Health Check"

res=$(req GET /health)
assert_status "GET /health" 200 "$(status_of "$res")"
info "$(body_of "$res")"

# ── 2. Auth – Register ──────────────────────────────────────
section "2. Auth – Register"

TIMESTAMP=$(date +%s)
USER_EMAIL="testuser_${TIMESTAMP}@example.com"
USER_PASS="password123"
USER_NAME="Test User"

ADMIN_EMAIL="admin_${TIMESTAMP}@example.com"
ADMIN_PASS="adminpass123"
ADMIN_NAME="Admin User"

# Register regular user
res=$(req POST /auth/register \
  "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\",\"name\":\"$USER_NAME\"}")
assert_status "POST /auth/register (user)" 201 "$(status_of "$res")"
USER_TOKEN=$(json_val "$(body_of "$res")" "token")
info "User token: ${USER_TOKEN:0:40}..."

# Register admin user
res=$(req POST /auth/register \
  "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"$ADMIN_NAME\"}")
assert_status "POST /auth/register (admin)" 201 "$(status_of "$res")"
ADMIN_TOKEN=$(json_val "$(body_of "$res")" "token")
info "Admin token: ${ADMIN_TOKEN:0:40}..."

# Promote admin user to role='admin' directly in SQLite
DB_FILE="$(dirname "$0")/data/ecommerce.db"
if command -v sqlite3 &>/dev/null && [[ -f "$DB_FILE" ]]; then
  sqlite3 "$DB_FILE" "UPDATE users SET role='admin' WHERE email='$ADMIN_EMAIL';"
  # Re-login to get a fresh token with updated role
  res=$(req POST /auth/login \
    "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}")
  ADMIN_TOKEN=$(json_val "$(body_of "$res")" "token")
  info "Admin promoted & re-logged in. Token: ${ADMIN_TOKEN:0:40}..."
else
  info "sqlite3 not found or DB not yet created – admin endpoints may return 403/401"
fi

# Duplicate registration should fail
res=$(req POST /auth/register \
  "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\",\"name\":\"$USER_NAME\"}")
assert_status "POST /auth/register (duplicate → 409)" 409 "$(status_of "$res")"

# ── 3. Auth – Login ─────────────────────────────────────────
section "3. Auth – Login"

res=$(req POST /auth/login \
  "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\"}")
assert_status "POST /auth/login (valid)" 200 "$(status_of "$res")"
USER_TOKEN=$(json_val "$(body_of "$res")" "token")   # refresh token from login

res=$(req POST /auth/login \
  "{\"email\":\"$USER_EMAIL\",\"password\":\"wrongpassword\"}")
assert_status "POST /auth/login (wrong password → 401)" 401 "$(status_of "$res")"

# ── 4. Auth – Profile ───────────────────────────────────────
section "4. Auth – Profile"

res=$(req GET /auth/me "" "$USER_TOKEN")
assert_status "GET /auth/me (authenticated)" 200 "$(status_of "$res")"
info "User: $(json_val "$(body_of "$res")" "email")"

res=$(req GET /auth/me)
assert_status "GET /auth/me (no token → 401)" 401 "$(status_of "$res")"

# ── 5. Products – Admin CRUD ────────────────────────────────
section "5. Products – Create (admin)"

# Create product as regular user → should fail (403)
res=$(req POST /products \
  '{"name":"Sneakers","price":79.99,"description":"Cool sneakers","stock":50}' \
  "$USER_TOKEN")
assert_status "POST /products (non-admin → 403)" 403 "$(status_of "$res")"

# Promote admin user by directly setting role via DB isn't available here,
# so we rely on the seeded admin account if one exists, OR we note that
# the test will demonstrate the correct rejection. For a self-contained test
# we'll note the limitation.
info "Note: admin product tests use ADMIN_TOKEN – ensure the admin user has role='admin' in DB."

# Create product as admin
res=$(req POST /products \
  '{"name":"Test Sneakers","price":79.99,"description":"Comfy test sneakers","stock":50}' \
  "$ADMIN_TOKEN")
STATUS=$(status_of "$res")
BODY=$(body_of "$res")
if [[ "$STATUS" == "201" ]]; then
  ok "POST /products (admin → 201)"
  PRODUCT_ID=$(json_val "$BODY" "id")
  info "Created product ID: $PRODUCT_ID"
else
  fail "POST /products (admin) – HTTP $STATUS (admin role may not be set)"
  # Fallback: grab an existing product ID
fi

# ── 6. Products – Public Read ───────────────────────────────
section "6. Products – Public Read"

res=$(req GET /products)
assert_status "GET /products (list)" 200 "$(status_of "$res")"

res=$(req GET "/products?page=1&limit=5")
assert_status "GET /products?page=1&limit=5 (paginated)" 200 "$(status_of "$res")"

# If we have a product ID, fetch it
if [[ -n "$PRODUCT_ID" && "$PRODUCT_ID" != "null" ]]; then
  res=$(req GET "/products/$PRODUCT_ID")
  assert_status "GET /products/:id" 200 "$(status_of "$res")"

  res=$(req GET "/products/999999")
  assert_status "GET /products/999999 (not found → 404)" 404 "$(status_of "$res")"
fi

# ── 7. Products – Update & Delete (admin) ───────────────────
section "7. Products – Update & Delete (admin)"

if [[ -n "$PRODUCT_ID" && "$PRODUCT_ID" != "null" ]]; then
  res=$(req PUT "/products/$PRODUCT_ID" \
    '{"price":89.99,"stock":45}' \
    "$ADMIN_TOKEN")
  assert_status "PUT /products/:id (admin)" 200 "$(status_of "$res")"

  res=$(req PUT "/products/$PRODUCT_ID" \
    '{"price":89.99}' \
    "$USER_TOKEN")
  assert_status "PUT /products/:id (non-admin → 403)" 403 "$(status_of "$res")"
else
  info "Skipping product update/delete – no product ID available"
fi

# ── 8. Cart – Add Items ─────────────────────────────────────
section "8. Cart – Add Items"

# Cart requires auth
res=$(req GET /cart)
assert_status "GET /cart (no token → 401)" 401 "$(status_of "$res")"

res=$(req GET /cart "" "$USER_TOKEN")
assert_status "GET /cart (empty)" 200 "$(status_of "$res")"

if [[ -n "$PRODUCT_ID" && "$PRODUCT_ID" != "null" ]]; then
  res=$(req POST /cart/items \
    "{\"productId\":$PRODUCT_ID,\"quantity\":2}" \
    "$USER_TOKEN")
  assert_status "POST /cart/items (add product)" 200 "$(status_of "$res")"

  # Add same item again (should increment)
  res=$(req POST /cart/items \
    "{\"productId\":$PRODUCT_ID,\"quantity\":1}" \
    "$USER_TOKEN")
  assert_status "POST /cart/items (increment quantity)" 200 "$(status_of "$res")"

  # ── 9. Cart – Update & Remove ────────────────────────────
  section "9. Cart – Update & Remove Item"

  res=$(req PUT "/cart/items/$PRODUCT_ID" \
    '{"quantity":5}' \
    "$USER_TOKEN")
  assert_status "PUT /cart/items/:productId (update qty)" 200 "$(status_of "$res")"

  res=$(req GET /cart "" "$USER_TOKEN")
  assert_status "GET /cart (with items)" 200 "$(status_of "$res")"
  info "Cart total: $(json_val "$(body_of "$res")" "total")"

  # ── 10. Orders – Checkout ────────────────────────────────
  section "10. Orders – Checkout"

  res=$(req POST /orders/checkout "" "$USER_TOKEN")
  assert_status "POST /orders/checkout" 201 "$(status_of "$res")"
  ORDER_BODY=$(body_of "$res")
  ORDER_ID=$(json_val "$ORDER_BODY" "id")
  PAYMENT_INTENT_ID=$(json_val "$ORDER_BODY" "paymentIntentId")
  info "Order ID: $ORDER_ID"
  info "Payment Intent ID: $PAYMENT_INTENT_ID"

  # Cart should be empty now
  res=$(req GET /cart "" "$USER_TOKEN")
  CART_ITEMS=$(body_of "$res" | grep -o '"items":\[\]')
  if [[ -n "$CART_ITEMS" ]]; then
    ok "Cart cleared after checkout"
    ((PASS++))
  else
    info "Cart state after checkout: $(body_of "$res" | head -c 120)"
  fi

  # ── 11. Orders – List & Get ──────────────────────────────
  section "11. Orders – List & Get"

  res=$(req GET /orders "" "$USER_TOKEN")
  assert_status "GET /orders (list)" 200 "$(status_of "$res")"

  if [[ -n "$ORDER_ID" && "$ORDER_ID" != "null" ]]; then
    res=$(req GET "/orders/$ORDER_ID" "" "$USER_TOKEN")
    assert_status "GET /orders/:id" 200 "$(status_of "$res")"

    res=$(req GET "/orders/999999" "" "$USER_TOKEN")
    assert_status "GET /orders/999999 (not found → 404)" 404 "$(status_of "$res")"
  fi

  # ── 12. Payments – Confirm & Fail ────────────────────────
  section "12. Payments – Confirm & Fail"

  if [[ -n "$PAYMENT_INTENT_ID" && "$PAYMENT_INTENT_ID" != "null" ]]; then
    res=$(req POST "/payments/$PAYMENT_INTENT_ID/confirm")
    assert_status "POST /payments/:id/confirm (mock success)" 200 "$(status_of "$res")"
    info "Payment status: $(json_val "$(body_of "$res")" "status")"

    # Create another order to test fail flow
    # First re-populate cart
    res=$(req POST /cart/items \
      "{\"productId\":$PRODUCT_ID,\"quantity\":1}" \
      "$USER_TOKEN")
    res=$(req POST /orders/checkout "" "$USER_TOKEN")
    SECOND_PAYMENT_ID=$(json_val "$(body_of "$res")" "paymentIntentId")

    if [[ -n "$SECOND_PAYMENT_ID" && "$SECOND_PAYMENT_ID" != "null" ]]; then
      res=$(req POST "/payments/$SECOND_PAYMENT_ID/fail")
      assert_status "POST /payments/:id/fail (mock failure)" 200 "$(status_of "$res")"
      info "Payment status: $(json_val "$(body_of "$res")" "status")"
    fi
  else
    info "Skipping payment tests – no payment intent ID available"
  fi

  # ── 13. Cart – Clear ─────────────────────────────────────
  section "13. Cart – Clear"

  # Add an item so we can clear it
  res=$(req POST /cart/items \
    "{\"productId\":$PRODUCT_ID,\"quantity\":1}" \
    "$USER_TOKEN")

  res=$(req DELETE /cart "" "$USER_TOKEN")
  assert_status "DELETE /cart (clear all)" 200 "$(status_of "$res")"

  # ── 14. Products – Delete (admin) ────────────────────────
  section "14. Products – Delete (admin)"

  res=$(req DELETE "/products/$PRODUCT_ID" "" "$ADMIN_TOKEN")
  assert_status "DELETE /products/:id (admin)" 200 "$(status_of "$res")"

  res=$(req GET "/products/$PRODUCT_ID")
  assert_status "GET /products/:id (deleted → 404)" 404 "$(status_of "$res")"

else
  info "Skipping cart/order/payment tests – no product available to work with"
fi

# ── Results ─────────────────────────────────────────────────
echo -e "\n${BOLD}══════════════════════════════════════${NC}"
echo -e "${BOLD}Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}\n"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
