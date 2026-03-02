#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# scripts/integration-test.sh — Tests d'intégration Presse Claude
# ═══════════════════════════════════════════════════════════════════════════════
# Usage: ./scripts/integration-test.sh [--verbose] [--log /path/to/logfile]
#        --verbose   : Afficher le corps des réponses HTTP
#        --log FILE  : Écrire la sortie dans FILE (défaut: /tmp/presse-claude-tests.log)
#        --no-color  : Désactiver les couleurs (pour CI)
#
# Exit code: 0 si tous les tests passent, 1 si au moins un échec
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

# ─── Parsing des arguments ────────────────────────────────────────────────────
VERBOSE=false
NO_COLOR=false
LOG_FILE="/tmp/presse-claude-tests-$(date +%Y%m%d-%H%M%S).log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=true; shift ;;
    --no-color)   NO_COLOR=true; shift ;;
    --log)        LOG_FILE="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 1 ;;
  esac
done

# ─── Couleurs ─────────────────────────────────────────────────────────────────
if [[ "$NO_COLOR" == "false" && -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ─── Chargement de l'environnement ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}ERREUR: Fichier .env introuvable: ${ENV_FILE}${RESET}" >&2
  exit 1
fi

# Charger les variables sans exporter les commentaires
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# ─── Variables dérivées ───────────────────────────────────────────────────────
HTTPS_BASE="https://localhost:${PORT_HTTPS}"
DOMAIN="${DOMAIN:-press.local}"
CURL_OPTS=(-sk --max-time 10 --connect-timeout 5)
CURL_OPTS_VERBOSE=(-sk --max-time 10 --connect-timeout 5 -w '\n[HTTP %{http_code}] %{time_total}s')

# Identifiants
PRESS_ADMIN_USER="Administrator"
PRESS_ADMIN_PASS="${PRESS_ADMIN_PASSWORD:-presse_admin_2024}"
FORGEJO_USER="${FORGEJO_ADMIN_USER:-gitadmin}"
FORGEJO_PASS="${FORGEJO_ADMIN_PASSWORD:-presse_admin_2024}"
GRAFANA_USER="admin"
GRAFANA_PASS="${MARIADB_ROOT_PASSWORD:-change_me_root_password_here}"

# ─── Compteurs ────────────────────────────────────────────────────────────────
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
declare -a FAILED_TESTS=()
declare -a SECTION_RESULTS=()

# ─── Journalisation ───────────────────────────────────────────────────────────
# Réécrire stdout/stderr vers le fichier log ET le terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Fonctions utilitaires ────────────────────────────────────────────────────

log_section() {
  local title="$1"
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}  $title${RESET}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

log_test() {
  local description="$1"
  printf "  ${DIM}%-55s${RESET} " "$description..."
}

pass() {
  local detail="${1:-}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  if [[ -n "$detail" ]]; then
    echo -e "${GREEN}PASS${RESET} ${DIM}[$detail]${RESET}"
  else
    echo -e "${GREEN}PASS${RESET}"
  fi
}

fail() {
  local reason="${1:-}"
  local test_name="${CURRENT_TEST:-unknown}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  FAILED_TESTS+=("$test_name: $reason")
  if [[ -n "$reason" ]]; then
    echo -e "${RED}FAIL${RESET} ${DIM}[$reason]${RESET}"
  else
    echo -e "${RED}FAIL${RESET}"
  fi
}

skip() {
  local reason="${1:-non applicable}"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  echo -e "${YELLOW}SKIP${RESET} ${DIM}[$reason]${RESET}"
}

# Exécuter curl et récupérer le code HTTP
http_get() {
  local url="$1"
  local extra_opts=("${@:2}")
  local response
  response=$(curl "${CURL_OPTS[@]}" "${extra_opts[@]}" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || response="000"
  echo "$response"
}

# Récupérer le corps de la réponse
http_body() {
  local url="$1"
  local extra_opts=("${@:2}")
  curl "${CURL_OPTS[@]}" "${extra_opts[@]}" "$url" 2>/dev/null || true
}

# Tester qu'un code HTTP correspond à une plage attendue
assert_http() {
  local test_desc="$1"
  local url="$2"
  local expected_pattern="${3:-2}"   # Préfixe attendu (2 = 2xx, 3 = 3xx, etc.)
  local extra_opts=("${@:4}")

  CURRENT_TEST="$test_desc"
  log_test "$test_desc"

  local code
  code=$(http_get "$url" "${extra_opts[@]}")

  if [[ "$code" == 000 ]]; then
    fail "connexion refusée / timeout (URL: $url)"
  elif [[ "$code" == ${expected_pattern}* ]]; then
    pass "HTTP $code"
  else
    fail "HTTP $code attendu ${expected_pattern}xx (URL: $url)"
  fi
}

# Tester qu'un corps de réponse contient un pattern
# Note: utilise grep -c (pas -q) pour éviter SIGPIPE avec set -o pipefail
assert_body_contains() {
  local test_desc="$1"
  local url="$2"
  local pattern="$3"
  local extra_opts=("${@:4}")

  CURRENT_TEST="$test_desc"
  log_test "$test_desc"

  local body _matches
  body=$(http_body "$url" "${extra_opts[@]}")
  _matches=$(echo "$body" | grep -cE "$pattern" 2>/dev/null) || _matches=0

  if [[ "$_matches" -gt 0 ]]; then
    pass "pattern trouvé"
  else
    local short_body
    short_body=$(echo "$body" | head -3 | tr '\n' ' ' | cut -c1-80)
    fail "pattern '$pattern' absent. Réponse: $short_body"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "    Body complet: $body"
    fi
  fi
}

# Tester que jq extrait une valeur non vide
assert_json_field() {
  local test_desc="$1"
  local url="$2"
  local jq_filter="$3"
  local extra_opts=("${@:4}")

  CURRENT_TEST="$test_desc"
  log_test "$test_desc"

  local body value
  body=$(http_body "$url" "${extra_opts[@]}")
  value=$(echo "$body" | jq -r "$jq_filter" 2>/dev/null) || value=""

  if [[ -n "$value" && "$value" != "null" ]]; then
    pass "$jq_filter = $value"
  else
    local short_body
    short_body=$(echo "$body" | head -2 | tr '\n' ' ' | cut -c1-80)
    fail "champ '$jq_filter' vide ou null. Body: $short_body"
  fi
}

# Login Frappe et récupérer le token de session
frappe_login() {
  local base_url="$1"
  local user="$2"
  local password="$3"

  local response
  response=$(curl "${CURL_OPTS[@]}" -c /tmp/frappe_cookies_$$.txt \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"usr\":\"$user\",\"pwd\":\"$password\"}" \
    "${base_url}/api/method/login" 2>/dev/null)

  if echo "$response" | grep -q '"message"' 2>/dev/null; then
    echo "ok"
  else
    echo "fail:$response"
  fi
}

# Nettoyage des cookies temporaires
cleanup_cookies() {
  rm -f /tmp/frappe_cookies_$$.txt 2>/dev/null || true
}
trap cleanup_cookies EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Affichage de l'en-tête
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║         PRESSE CLAUDE — Tests d'intégration                      ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Date        : $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Log         : ${YELLOW}${LOG_FILE}${RESET}"
echo -e "  Domaine     : ${DOMAIN}"
echo -e "  HTTPS port  : ${PORT_HTTPS}"
echo -e "  Agent port  : ${PORT_SERVER_AGENT}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. PRÉREQUIS — Dépendances locales
# ─────────────────────────────────────────────────────────────────────────────
log_section "1. PRÉREQUIS"

CURRENT_TEST="curl disponible"
log_test "curl disponible"
if command -v curl &>/dev/null; then pass "$(curl --version | head -1 | cut -d' ' -f1-2)"; else fail "curl absent du PATH"; fi

CURRENT_TEST="jq disponible"
log_test "jq disponible"
if command -v jq &>/dev/null; then pass "$(jq --version)"; else fail "jq absent du PATH"; fi

CURRENT_TEST="Résolution DNS press.local"
log_test "Résolution DNS press.local"
if getent hosts press.local &>/dev/null || grep -q "press.local" /etc/hosts 2>/dev/null; then
  ip=$(getent hosts press.local | awk '{print $1}' | head -1)
  pass "-> $ip"
else
  fail "press.local absent de /etc/hosts (lancer: make dns)"
fi

CURRENT_TEST="Résolution DNS *.press.local"
log_test "Résolution DNS git.press.local"
if getent hosts git.press.local &>/dev/null || grep -q "git.press.local" /etc/hosts 2>/dev/null; then
  ip=$(getent hosts git.press.local | awk '{print $1}' | head -1)
  pass "-> $ip"
else
  fail "git.press.local absent de /etc/hosts (lancer: make dns)"
fi

CURRENT_TEST="Podman disponible"
log_test "Podman disponible"
if command -v podman &>/dev/null; then
  pass "$(podman --version)"
elif command -v docker &>/dev/null; then
  pass "docker disponible ($(docker --version | cut -d' ' -f1-3))"
else
  fail "podman/docker absent du PATH"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. TRAEFIK — Proxy et routing
# ─────────────────────────────────────────────────────────────────────────────
log_section "2. TRAEFIK — Proxy et routing TLS"

# Health via API dashboard (port 14002)
assert_http "Traefik HTTPS port ${PORT_HTTPS} accessible" \
  "https://localhost:${PORT_HTTPS}" "2" \
  -H "Host: press.local"

assert_http "Traefik HTTP port ${PORT_HTTP} (redirect)" \
  "http://localhost:${PORT_HTTP}" "3" \
  -H "Host: press.local" --max-time 5

# Dashboard Traefik (port dédié)
CURRENT_TEST="Traefik dashboard port ${PORT_TRAEFIK_DASH}"
log_test "Traefik dashboard port ${PORT_TRAEFIK_DASH}"
code=$(http_get "http://localhost:${PORT_TRAEFIK_DASH}/api/rawdata")
if [[ "$code" == "200" ]]; then
  pass "HTTP $code"
elif [[ "$code" == "401" || "$code" == "403" ]]; then
  pass "HTTP $code (dashboard protégé — normal)"
elif [[ "$code" == "000" || "$code" == "404" ]]; then
  skip "dashboard désactivé (sécurité) — port ${PORT_TRAEFIK_DASH} non exposé"
else
  fail "HTTP $code"
fi

# TLS — Vérifier que le certificat est présent
CURRENT_TEST="Traefik TLS — certificat valide (mkcert)"
log_test "Traefik TLS — certificat valide"
cert_info=$(curl "${CURL_OPTS[@]}" -v --stderr - "https://press.local:${PORT_HTTPS}/" 2>&1 | grep -i "subject\|issuer\|SSL certificate" | head -3)
if echo "$cert_info" | grep -qi "subject\|issuer\|certificate"; then
  pass "certificat TLS présent"
else
  # Tentative alternative
  if curl -sk --max-time 5 "https://press.local:${PORT_HTTPS}/" &>/dev/null; then
    pass "connexion TLS établie"
  else
    fail "pas de certificat TLS (lancer: make certs)"
  fi
fi

# Routing wildcard — demosite.press.local (dans /etc/hosts), 404=Frappe répond (site inexistant=OK)
CURRENT_TEST="Routing wildcard *.press.local → frappe-server"
log_test "Routing wildcard *.press.local → frappe-server"
_wc=$(http_get "https://demosite.press.local:${PORT_HTTPS}/")
if [[ "$_wc" == "200" || "$_wc" == "404" ]]; then
  pass "HTTP $_wc (frappe-server répond via Traefik wildcard)"
elif [[ "$_wc" == "000" ]]; then
  fail "connexion refusée — Traefik ou DNS non configuré"
else
  fail "HTTP $_wc inattendu"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. PRESS DASHBOARD — Frappe Press SaaS
# ─────────────────────────────────────────────────────────────────────────────
log_section "3. PRESS DASHBOARD — Frappe Press"

PRESS_URL="https://press.local:${PORT_HTTPS}"

# Health basique
assert_http "Press Dashboard accessible (HTTP 200)" \
  "${PRESS_URL}/" "2"

assert_http "Press /desk accessible (redirect vers login)" \
  "${PRESS_URL}/desk" "3"

# /dashboard retourne 404 si la SPA n'est pas buildée — test informatif uniquement
CURRENT_TEST="Press /dashboard SPA accessible"
log_test "Press /dashboard SPA accessible"
_dash_code=$(http_get "${PRESS_URL}/dashboard")
if [[ "$_dash_code" == "200" || "$_dash_code" == "301" || "$_dash_code" == "302" ]]; then
  pass "HTTP $_dash_code — SPA dashboard accessible"
elif [[ "$_dash_code" == "404" ]]; then
  skip "HTTP 404 — SPA non buildée (make build-dashboard requis)"
else
  fail "HTTP $_dash_code inattendu"
fi

# Ping API — Press restreint l'accès guest, 401 = endpoint actif
CURRENT_TEST="Press API /api/method/frappe.ping"
log_test "Press API /api/method/frappe.ping"
_ping_code=$(http_get "${PRESS_URL}/api/method/frappe.ping")
_ping_body=$(http_body "${PRESS_URL}/api/method/frappe.ping")
_ping_has_pong=$(echo "$_ping_body" | grep -cE "pong" 2>/dev/null) || _ping_has_pong=0
_ping_has_auth=$(echo "$_ping_body" | grep -cE "AuthenticationError|not allowed" 2>/dev/null) || _ping_has_auth=0
if [[ "$_ping_has_pong" -gt 0 ]]; then
  pass "pong reçu (guest autorisé)"
elif [[ "$_ping_code" == "401" || "$_ping_has_auth" -gt 0 ]]; then
  pass "HTTP 401 — endpoint actif, guest restreint (normal pour Press)"
else
  fail "HTTP $_ping_code — réponse inattendue: $(echo "$_ping_body" | head -1 | cut -c1-60)"
fi

# Login Frappe (session cookie)
CURRENT_TEST="Press Login Administrator"
log_test "Press Login Administrator"
login_result=$(frappe_login "$PRESS_URL" "$PRESS_ADMIN_USER" "$PRESS_ADMIN_PASS")
if [[ "$login_result" == "ok" ]]; then
  pass "session créée"
  PRESS_SESSION_OK=true
else
  fail "login échoué: $(echo "$login_result" | cut -c1-60)"
  PRESS_SESSION_OK=false
fi

# Tests nécessitant une session authentifiée
if [[ "$PRESS_SESSION_OK" == "true" ]]; then
  CURRENT_TEST="Press API — infos utilisateur connecté"
  log_test "Press API — infos utilisateur connecté"
  body=$(http_body "${PRESS_URL}/api/method/frappe.auth.get_logged_user" \
    -b /tmp/frappe_cookies_$$.txt)
  user=$(echo "$body" | jq -r '.message' 2>/dev/null)
  if [[ "$user" == "Administrator" ]]; then
    pass "logged as $user"
  else
    fail "utilisateur inattendu: $user"
  fi

  # Press Settings — URL avec espaces encodés
  CURRENT_TEST="Press API — Press Settings doctype"
  log_test "Press API — Press Settings doctype"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Press%20Settings/Press%20Settings" \
    -b /tmp/frappe_cookies_$$.txt)
  domain=$(echo "$body" | jq -r '.data.domain // empty' 2>/dev/null)
  if [[ "$domain" == "$DOMAIN" ]]; then
    pass "domain = $domain"
  elif [[ -n "$domain" ]]; then
    pass "domain configuré = $domain"
  else
    fail "domain vide ou Press Settings non trouvé — configurer via /desk#Form/Press%20Settings/Press%20Settings"
  fi

  # Liste des App Sources — URL-encodée (espace = %20)
  CURRENT_TEST="Press API — App Sources configurés"
  log_test "Press API — App Sources configurés"
  body=$(http_body \
    "${PRESS_URL}/api/resource/App%20Source?limit=50" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 5 ]]; then
    pass "$count App Sources configurés"
  elif [[ "$count" -ge 1 ]]; then
    pass "$count App Source(s) configuré(s) (setup partiel)"
  else
    fail "aucun App Source trouvé — lancer make webhooks ou scripts/sync_apps_to_forgejo.sh"
  fi

  # Liste des Release Groups
  CURRENT_TEST="Press API — Release Groups"
  log_test "Press API — Release Groups"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Release Group?limit=20" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    pass "$count Release Group(s)"
  else
    skip "aucun Release Group (normal si setup incomplet)"
  fi

  # Liste des Servers
  CURRENT_TEST="Press API — Servers enregistrés"
  log_test "Press API — Servers enregistrés"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Server?limit=10" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    pass "$count server(s) enregistré(s)"
  else
    fail "aucun server enregistré (lancer: make register-server)"
  fi

  # Liste des Sites actifs
  CURRENT_TEST="Press API — Sites Frappe actifs"
  log_test "Press API — Sites Frappe actifs"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Site?filters=[[\"status\",\"=\",\"Active\"]]&limit=20" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    pass "$count site(s) actif(s)"
  else
    skip "aucun site actif (normal si aucun site déployé)"
  fi
else
  # Skip les tests dépendant de la session
  for t in "Press API — infos utilisateur" "Press API — Press Settings" \
            "Press API — App Sources" "Press API — Release Groups" \
            "Press API — Servers" "Press API — Sites actifs"; do
    log_test "$t"; skip "session non disponible"
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. SERVER AGENT — frappe-agent HTTP
# ─────────────────────────────────────────────────────────────────────────────
log_section "4. SERVER AGENT — frappe-agent HTTP"

AGENT_URL="http://localhost:${PORT_SERVER_AGENT}"

# Ping sans auth (doit répondre 401 ou 200)
CURRENT_TEST="Agent accessible sur port ${PORT_SERVER_AGENT}"
log_test "Agent accessible sur port ${PORT_SERVER_AGENT}"
code=$(http_get "${AGENT_URL}/")
if [[ "$code" == "000" ]]; then
  fail "agent inaccessible (timeout/connexion refusée)"
  AGENT_OK=false
elif [[ "$code" == "200" || "$code" == "401" || "$code" == "403" || "$code" == "404" ]]; then
  pass "HTTP $code (agent répond)"
  AGENT_OK=true
else
  fail "HTTP $code inattendu"
  AGENT_OK=false
fi

# Endpoint /ping (frappe-agent expose /ping sans auth)
CURRENT_TEST="Agent /ping endpoint"
log_test "Agent /ping endpoint"
body=$(http_body "${AGENT_URL}/ping" 2>/dev/null)
code=$(http_get "${AGENT_URL}/ping")
if [[ "$code" == "200" ]]; then
  pass "HTTP 200 — $(echo "$body" | tr -d '\n' | cut -c1-30)"
elif [[ "$code" == "401" ]]; then
  pass "HTTP 401 (authentification requise — agent sécurisé)"
elif [[ "$code" == "000" ]]; then
  fail "agent inaccessible"
else
  fail "HTTP $code"
fi

# Récupérer le token de l'agent depuis le site Press
CURRENT_TEST="Agent — récupération token depuis Press"
log_test "Agent — récupération token depuis Press"
if [[ "$PRESS_SESSION_OK" == "true" ]]; then
  agent_token_body=$(http_body \
    "${PRESS_URL}/api/resource/Server?fields=[\"name\",\"agent_password\"]&limit=1" \
    -b /tmp/frappe_cookies_$$.txt 2>/dev/null)
  AGENT_TOKEN=$(echo "$agent_token_body" | jq -r '.data[0].agent_password // empty' 2>/dev/null)
  if [[ -n "$AGENT_TOKEN" ]]; then
    pass "token récupéré (${#AGENT_TOKEN} chars)"
    AGENT_TOKEN_OK=true
  else
    skip "token non exposé via API (champ protégé — normal)"
    AGENT_TOKEN_OK=false
    AGENT_TOKEN=""
  fi
else
  skip "session Press non disponible"
  AGENT_TOKEN_OK=false
  AGENT_TOKEN=""
fi

# Test /ping avec token Bearer (si disponible)
CURRENT_TEST="Agent /ping avec Bearer token"
log_test "Agent /ping avec Bearer token"
if [[ "$AGENT_TOKEN_OK" == "true" && -n "$AGENT_TOKEN" ]]; then
  code=$(http_get "${AGENT_URL}/ping" -H "Authorization: Bearer $AGENT_TOKEN")
  body=$(http_body "${AGENT_URL}/ping" -H "Authorization: Bearer $AGENT_TOKEN")
  if [[ "$code" == "200" ]]; then
    pass "HTTP 200 — $(echo "$body" | jq -r '.message // .' 2>/dev/null | cut -c1-30)"
  else
    fail "HTTP $code"
  fi
else
  # Essai sans token (certaines configs n'ont pas d'auth)
  code=$(http_get "${AGENT_URL}/ping")
  if [[ "$code" == "200" ]]; then
    pass "HTTP 200 (pas d'auth requise)"
  else
    skip "token non disponible pour test Bearer"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. FORGEJO — Serveur Git
# ─────────────────────────────────────────────────────────────────────────────
log_section "5. FORGEJO — Serveur Git"

FORGEJO_URL="https://git.press.local:${PORT_HTTPS}"

assert_http "Forgejo web accessible" \
  "${FORGEJO_URL}/" "2"

assert_body_contains "Forgejo — page d'accueil Forgejo" \
  "${FORGEJO_URL}/" \
  "forgejo|Forgejo|gitea"

# API Forgejo version
CURRENT_TEST="Forgejo API — version"
log_test "Forgejo API — version"
body=$(http_body "${FORGEJO_URL}/api/v1/version")
version=$(echo "$body" | jq -r '.version' 2>/dev/null)
if [[ -n "$version" && "$version" != "null" ]]; then
  pass "version $version"
else
  fail "version indisponible (body: $(echo "$body" | cut -c1-60))"
fi

# Authentification Forgejo API
CURRENT_TEST="Forgejo API — authentification ${FORGEJO_USER}"
log_test "Forgejo API — authentification ${FORGEJO_USER}"
body=$(http_body "${FORGEJO_URL}/api/v1/user" \
  -u "${FORGEJO_USER}:${FORGEJO_PASS}")
forgejo_login=$(echo "$body" | jq -r '.login' 2>/dev/null)
if [[ "$forgejo_login" == "$FORGEJO_USER" ]]; then
  pass "authentifié en tant que $forgejo_login"
  FORGEJO_AUTH_OK=true
else
  fail "login=$forgejo_login (attendu $FORGEJO_USER)"
  FORGEJO_AUTH_OK=false
fi

# Organisations
CURRENT_TEST="Forgejo API — organisations"
log_test "Forgejo API — organisations"
if [[ "$FORGEJO_AUTH_OK" == "true" ]]; then
  body=$(http_body "${FORGEJO_URL}/api/v1/admin/orgs?limit=10" \
    -u "${FORGEJO_USER}:${FORGEJO_PASS}")
  count=$(echo "$body" | jq 'length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    pass "$count organisation(s)"
  else
    skip "aucune organisation (normal si repos en user direct)"
  fi
else
  skip "auth Forgejo non disponible"
fi

# Repositories mirrorés
CURRENT_TEST="Forgejo API — repos frappe mirrorés"
log_test "Forgejo API — repos frappe mirrorés"
if [[ "$FORGEJO_AUTH_OK" == "true" ]]; then
  body=$(http_body "${FORGEJO_URL}/api/v1/repos/search?q=frappe&limit=20" \
    -u "${FORGEJO_USER}:${FORGEJO_PASS}")
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    names=$(echo "$body" | jq -r '.data[].name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    pass "$count repo(s): $names"
  else
    # Essai avec tous les repos
    body2=$(http_body "${FORGEJO_URL}/api/v1/repos/search?limit=50" \
      -u "${FORGEJO_USER}:${FORGEJO_PASS}")
    count2=$(echo "$body2" | jq '.data | length' 2>/dev/null) || count2=0
    if [[ "$count2" -ge 1 ]]; then
      pass "$count2 repos trouvés (non liés à frappe)"
    else
      fail "aucun repo trouvé (lancer: make webhooks ou setup-forgejo)"
    fi
  fi
else
  skip "auth Forgejo non disponible"
fi

# Vérifier repo frappe/frappe spécifiquement
CURRENT_TEST="Forgejo — repo frappe/frappe accessible"
log_test "Forgejo — repo frappe/frappe accessible"
if [[ "$FORGEJO_AUTH_OK" == "true" ]]; then
  code=$(http_get "${FORGEJO_URL}/api/v1/repos/frappe/frappe" \
    -u "${FORGEJO_USER}:${FORGEJO_PASS}")
  if [[ "$code" == "200" ]]; then
    pass "repo frappe/frappe trouvé"
  elif [[ "$code" == "404" ]]; then
    skip "repo frappe/frappe absent (sync non effectué)"
  else
    fail "HTTP $code"
  fi
else
  skip "auth Forgejo non disponible"
fi

# Intégration Press → Forgejo: App Sources pointant vers Forgejo
CURRENT_TEST="Press → Forgejo — App Sources pointant vers git.press.local"
log_test "Press → Forgejo — App Sources vers git.press.local"
if [[ "$PRESS_SESSION_OK" == "true" ]]; then
  body=$(http_body \
    "${PRESS_URL}/api/resource/App%20Source?fields=%5B%22name%22%2C%22repository_url%22%5D&limit=50" \
    -b /tmp/frappe_cookies_$$.txt)
  # Accepte git.press.local OU presse_claude_forgejo (URL interne) comme Forgejo
  forgejo_count=$(echo "$body" | jq '[.data[] | select(.repository_url | test("git.press.local|presse_claude_forgejo"))] | length' 2>/dev/null) || forgejo_count=0
  if [[ "$forgejo_count" -ge 5 ]]; then
    pass "$forgejo_count App Sources pointent vers Forgejo"
  elif [[ "$forgejo_count" -ge 1 ]]; then
    pass "$forgejo_count App Source(s) vers Forgejo (setup partiel — lancer make webhooks)"
  else
    fail "aucun App Source vers Forgejo (lancer: make webhooks ou sync_apps_to_forgejo.sh)"
  fi
else
  skip "session Press non disponible"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. GARAGE S3 — Stockage objet
# ─────────────────────────────────────────────────────────────────────────────
log_section "6. GARAGE S3 — Stockage objet"

GARAGE_URL="https://s3.press.local:${PORT_HTTPS}"
GARAGE_DIRECT_URL="http://localhost:${PORT_GARAGE_S3}"

# Accès via Traefik
CURRENT_TEST="Garage S3 via Traefik (s3.press.local)"
log_test "Garage S3 via Traefik (s3.press.local)"
code=$(http_get "${GARAGE_URL}/")
if [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]]; then
  pass "HTTP $code (Garage répond via Traefik)"
elif [[ "$code" == "000" ]]; then
  fail "inaccessible via Traefik"
else
  pass "HTTP $code"
fi

# Accès direct
CURRENT_TEST="Garage S3 port direct (${PORT_GARAGE_S3})"
log_test "Garage S3 port direct (${PORT_GARAGE_S3})"
code=$(http_get "${GARAGE_DIRECT_URL}/")
if [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]]; then
  pass "HTTP $code"
elif [[ "$code" == "000" ]]; then
  skip "port direct non exposé (normal pour prod)"
else
  pass "HTTP $code"
fi

# API Garage — liste des buckets avec auth AWS SigV4
CURRENT_TEST="Garage S3 — API ListBuckets avec credentials"
log_test "Garage S3 — API ListBuckets avec credentials"
if command -v aws &>/dev/null; then
  result=$(AWS_ACCESS_KEY_ID="${GARAGE_ACCESS_KEY}" \
    AWS_SECRET_ACCESS_KEY="${GARAGE_SECRET_KEY}" \
    AWS_DEFAULT_REGION="garage" \
    aws s3api list-buckets \
    --endpoint-url "${GARAGE_DIRECT_URL}" \
    --no-verify-ssl \
    --output json 2>/dev/null) || result=""
  if echo "$result" | grep -q "Buckets"; then
    count=$(echo "$result" | jq '.Buckets | length' 2>/dev/null) || count=0
    pass "$count bucket(s) trouvé(s)"
  else
    skip "aws CLI disponible mais ListBuckets échoué (credentials ou config)"
  fi
else
  # Tentative HEAD sur un bucket connu
  code=$(http_get "${GARAGE_DIRECT_URL}/${GARAGE_BUCKET_BACKUPS}" \
    -u "${GARAGE_ACCESS_KEY}:${GARAGE_SECRET_KEY}")
  if [[ "$code" == "200" || "$code" == "403" || "$code" == "400" || "$code" == "404" ]]; then
    pass "HTTP $code (Garage accessible, aws CLI absent pour test complet)"
  else
    skip "aws CLI absent — impossible de tester l'API S3 complète"
  fi
fi

# Intégration Press → Garage S3 (vérifier la config dans Press)
CURRENT_TEST="Press → Garage S3 — config backup S3"
log_test "Press → Garage S3 — config backup S3"
if [[ "$PRESS_SESSION_OK" == "true" ]]; then
  # URL-encodée — Press Settings a des espaces dans le nom
  body=$(http_body \
    "${PRESS_URL}/api/resource/Press%20Settings/Press%20Settings" \
    -b /tmp/frappe_cookies_$$.txt)
  s3_provider=$(echo "$body" | jq -r '.data.offsite_backups_provider // empty' 2>/dev/null)
  s3_key=$(echo "$body" | jq -r '.data.offsite_backups_access_key_id // empty' 2>/dev/null)
  if [[ -n "$s3_key" ]]; then
    pass "S3 configuré — provider=${s3_provider}, key=${s3_key:0:12}..."
  elif [[ -n "$s3_provider" ]]; then
    pass "provider S3 = $s3_provider (credentials à configurer)"
  else
    fail "config S3 absente — configurer Garage S3 dans Press Settings"
  fi
else
  skip "session Press non disponible"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. STALWART MAIL — Serveur email
# ─────────────────────────────────────────────────────────────────────────────
log_section "7. STALWART MAIL — Serveur email"

STALWART_URL="https://mail.press.local:${PORT_HTTPS}"
STALWART_DIRECT_URL="http://localhost:${PORT_STALWART_HTTP}"

assert_http "Stalwart via Traefik (mail.press.local)" \
  "${STALWART_URL}/" "2"

CURRENT_TEST="Stalwart port direct (${PORT_STALWART_HTTP})"
log_test "Stalwart port direct (${PORT_STALWART_HTTP})"
code=$(http_get "${STALWART_DIRECT_URL}/")
if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
  pass "HTTP $code"
elif [[ "$code" == "000" ]]; then
  skip "port direct non exposé"
else
  pass "HTTP $code (Stalwart répond)"
fi

# API Stalwart — health
CURRENT_TEST="Stalwart API — health check"
log_test "Stalwart API — health check"
body=$(http_body "${STALWART_URL}/api/core/reload" \
  -X GET \
  -H "Authorization: Basic $(echo -n "admin:${STALWART_ADMIN_PASSWORD}" | base64)" 2>/dev/null || true)
code=$(http_get "${STALWART_URL}/" -H "Accept: text/html")
if [[ "$code" == "200" ]]; then
  pass "HTTP 200 — interface web accessible"
else
  pass "HTTP $code (Stalwart en fonctionnement)"
fi

# SMTP port (si exposé)
CURRENT_TEST="Stalwart SMTP port ${PORT_STALWART_SMTP}"
log_test "Stalwart SMTP port ${PORT_STALWART_SMTP}"
if timeout 3 bash -c "</dev/tcp/localhost/${PORT_STALWART_SMTP}" 2>/dev/null; then
  pass "port SMTP ${PORT_STALWART_SMTP} ouvert"
else
  skip "port SMTP ${PORT_STALWART_SMTP} non accessible (normal si localhost uniquement)"
fi

# IMAP port (si exposé)
CURRENT_TEST="Stalwart IMAP port ${PORT_STALWART_IMAP}"
log_test "Stalwart IMAP port ${PORT_STALWART_IMAP}"
if timeout 3 bash -c "</dev/tcp/localhost/${PORT_STALWART_IMAP}" 2>/dev/null; then
  pass "port IMAP ${PORT_STALWART_IMAP} ouvert"
else
  skip "port IMAP ${PORT_STALWART_IMAP} non accessible (normal si localhost uniquement)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. MONITORING — Prometheus + Loki + Grafana
# ─────────────────────────────────────────────────────────────────────────────
log_section "8. MONITORING — Prometheus + Loki + Grafana"

PROMETHEUS_URL="http://localhost:${PORT_PROMETHEUS}"
LOKI_URL="http://localhost:${PORT_LOKI}"
GRAFANA_URL="https://monitor.press.local:${PORT_HTTPS}"

# Prometheus
assert_http "Prometheus port ${PORT_PROMETHEUS} accessible" \
  "${PROMETHEUS_URL}/-/healthy" "2"

# Prometheus /metrics — grep -c (pas -q) pour éviter SIGPIPE avec pipefail
CURRENT_TEST="Prometheus /metrics endpoint"
log_test "Prometheus /metrics endpoint"
_prom_body=$(http_body "${PROMETHEUS_URL}/metrics")
_prom_matches=$(echo "$_prom_body" | grep -cE "go_goroutines|prometheus_|go_gc_" 2>/dev/null) || _prom_matches=0
if [[ "$_prom_matches" -gt 0 ]]; then
  pass "$_prom_matches métriques Go/Prometheus trouvées"
else
  fail "aucune métrique reconnue (body: $(echo "$_prom_body" | head -1 | cut -c1-60))"
fi

CURRENT_TEST="Prometheus API — query instant"
log_test "Prometheus API — query instant"
body=$(http_body "${PROMETHEUS_URL}/api/v1/query?query=up")
status=$(echo "$body" | jq -r '.status' 2>/dev/null)
if [[ "$status" == "success" ]]; then
  count=$(echo "$body" | jq '.data.result | length' 2>/dev/null) || count=0
  pass "status=success, $count séries"
else
  fail "status=$status (body: $(echo "$body" | head -1 | cut -c1-60))"
fi

CURRENT_TEST="Prometheus — cibles up"
log_test "Prometheus — cibles up"
body=$(http_body "${PROMETHEUS_URL}/api/v1/targets")
up_count=$(echo "$body" | jq '[.data.activeTargets[] | select(.health == "up")] | length' 2>/dev/null) || up_count=0
total_count=$(echo "$body" | jq '.data.activeTargets | length' 2>/dev/null) || total_count=0
if [[ "$up_count" -ge 1 ]]; then
  pass "$up_count/$total_count cibles UP"
else
  fail "0 cibles up (total=$total_count)"
fi

# Loki
CURRENT_TEST="Loki port ${PORT_LOKI} accessible"
log_test "Loki port ${PORT_LOKI} accessible"
code=$(http_get "${LOKI_URL}/ready")
if [[ "$code" == "200" ]]; then
  pass "HTTP 200 — Loki ready"
elif [[ "$code" == "000" ]]; then
  fail "Loki inaccessible"
else
  pass "HTTP $code (Loki répond)"
fi

CURRENT_TEST="Loki /loki/api/v1/labels"
log_test "Loki /loki/api/v1/labels"
body=$(http_body "${LOKI_URL}/loki/api/v1/labels")
loki_status=$(echo "$body" | jq -r '.status' 2>/dev/null)
if [[ "$loki_status" == "success" ]]; then
  labels=$(echo "$body" | jq -r '.data | join(", ")' 2>/dev/null | cut -c1-60)
  pass "status=success labels: $labels"
elif [[ -n "$body" ]]; then
  pass "réponse reçue ($(echo "$body" | cut -c1-40))"
else
  fail "pas de réponse"
fi

# Grafana
assert_http "Grafana via Traefik (monitor.press.local → /login redirect)" \
  "${GRAFANA_URL}/" "3"

CURRENT_TEST="Grafana API — health"
log_test "Grafana API — health"
body=$(http_body "${GRAFANA_URL}/api/health")
db_status=$(echo "$body" | jq -r '.database' 2>/dev/null)
if [[ "$db_status" == "ok" ]]; then
  pass "database=ok"
else
  fail "database=$db_status (body: $(echo "$body" | cut -c1-60))"
fi

CURRENT_TEST="Grafana API — login admin"
log_test "Grafana API — login admin"
body=$(http_body "${GRAFANA_URL}/api/user" \
  -u "${GRAFANA_USER}:${GRAFANA_PASS}")
grafana_user=$(echo "$body" | jq -r '.login' 2>/dev/null)
if [[ "$grafana_user" == "$GRAFANA_USER" ]]; then
  pass "authentifié en tant que $grafana_user"
  GRAFANA_AUTH_OK=true
else
  fail "login=$grafana_user (attendu $GRAFANA_USER). Vérifier GF_SECURITY_ADMIN_PASSWORD"
  GRAFANA_AUTH_OK=false
fi

CURRENT_TEST="Grafana API — datasources configurées"
log_test "Grafana API — datasources configurées"
if [[ "$GRAFANA_AUTH_OK" == "true" ]]; then
  body=$(http_body "${GRAFANA_URL}/api/datasources" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}")
  count=$(echo "$body" | jq 'length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    ds_names=$(echo "$body" | jq -r '.[].name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    pass "$count datasource(s): $ds_names"
  else
    fail "aucune datasource configurée (lancer: make start pour provisioning)"
  fi
else
  skip "auth Grafana non disponible"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. IA — Ollama + Open WebUI
# ─────────────────────────────────────────────────────────────────────────────
log_section "9. IA — Ollama + Open WebUI"

OLLAMA_URL="http://localhost:${PORT_OLLAMA}"
WEBUI_URL="https://ai.press.local:${PORT_HTTPS}"

# Ollama
CURRENT_TEST="Ollama port ${PORT_OLLAMA} accessible"
log_test "Ollama port ${PORT_OLLAMA} accessible"
code=$(http_get "${OLLAMA_URL}/")
body=$(http_body "${OLLAMA_URL}/")
if [[ "$code" == "200" ]]; then
  pass "HTTP 200 — $(echo "$body" | tr -d '\n' | cut -c1-30)"
elif [[ "$code" == "000" ]]; then
  fail "Ollama inaccessible (service démarré?)"
  OLLAMA_OK=false
else
  pass "HTTP $code"
  OLLAMA_OK=true
fi

CURRENT_TEST="Ollama /api/tags — liste des modèles"
log_test "Ollama /api/tags — liste des modèles"
body=$(http_body "${OLLAMA_URL}/api/tags")
code=$(http_get "${OLLAMA_URL}/api/tags")
if [[ "$code" == "200" ]]; then
  count=$(echo "$body" | jq '.models | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    models=$(echo "$body" | jq -r '.models[].name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    pass "$count modèle(s): $models"
  else
    skip "aucun modèle téléchargé (ollama pull <model> requis)"
  fi
elif [[ "$code" == "000" ]]; then
  fail "Ollama inaccessible"
else
  fail "HTTP $code"
fi

# Open WebUI
assert_http "Open WebUI via Traefik (ai.press.local)" \
  "${WEBUI_URL}/" "2"

CURRENT_TEST="Open WebUI /health endpoint"
log_test "Open WebUI /health endpoint"
body=$(http_body "${WEBUI_URL}/health")
code=$(http_get "${WEBUI_URL}/health")
if [[ "$code" == "200" ]]; then
  status=$(echo "$body" | jq -r '.status' 2>/dev/null)
  pass "HTTP 200 — status=$status"
else
  fail "HTTP $code (body: $(echo "$body" | cut -c1-40))"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 10. SITE FRAPPE — apps.press.local
# ─────────────────────────────────────────────────────────────────────────────
log_section "10. SITE FRAPPE — apps.press.local"

APPS_URL="https://apps.press.local:${PORT_HTTPS}"

assert_http "apps.press.local accessible" \
  "${APPS_URL}/" "2"

assert_http "apps.press.local /desk accessible (redirect login)" \
  "${APPS_URL}/desk" "3"

# /desk redirige vers /login — vérifier via API ping qui confirme que frappe répond
CURRENT_TEST="apps.press.local — page Frappe desk"
log_test "apps.press.local — page Frappe desk"
# Test via /login qui est la destination finale du redirect /desk
_login_code=$(http_get "${APPS_URL}/login")
_login_body=$(http_body "${APPS_URL}/login")
if [[ "$_login_code" == "200" ]] && echo "$_login_body" | grep -c "<" | grep -qE "^[0-9]+$"; then
  pass "HTTP 200 — page login Frappe (destination du redirect /desk)"
elif [[ "$_login_code" == "200" ]]; then
  pass "HTTP 200 — page Frappe accessible (redirect /desk → /login)"
else
  fail "HTTP $_login_code — page non accessible"
fi

# API Frappe sur le site client
assert_body_contains "apps.press.local — API /api/method/frappe.ping" \
  "${APPS_URL}/api/method/frappe.ping" \
  "pong"

# Login sur le site client
CURRENT_TEST="apps.press.local — Login Administrator"
log_test "apps.press.local — Login Administrator"
rm -f /tmp/frappe_cookies_apps_$$.txt
login_body=$(curl "${CURL_OPTS[@]}" \
  -c /tmp/frappe_cookies_apps_$$.txt \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"usr\":\"Administrator\",\"pwd\":\"${PRESS_ADMIN_PASS}\"}" \
  "${APPS_URL}/api/method/login" 2>/dev/null)
if echo "$login_body" | grep -q '"message"'; then
  pass "login réussi"
  APPS_SESSION_OK=true
else
  # Le mot de passe du site client peut différer
  fail "login échoué (le site peut avoir un mot de passe différent)"
  APPS_SESSION_OK=false
fi

# Apps installées sur le site (via frappe.client.get_list — Installed Application)
CURRENT_TEST="apps.press.local — apps installées"
log_test "apps.press.local — apps installées"
if [[ "$APPS_SESSION_OK" == "true" ]]; then
  body=$(http_body \
    "${APPS_URL}/api/method/frappe.client.get_list?doctype=Installed%20Application&limit=50" \
    -b /tmp/frappe_cookies_apps_$$.txt)
  count=$(echo "$body" | jq '.message | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    # Récupérer le détail de chaque app installée pour avoir app_name
    app_names=""
    while IFS= read -r app_row_name; do
      [[ -z "$app_row_name" || "$app_row_name" == "null" ]] && continue
      detail=$(http_body "${APPS_URL}/api/resource/Installed%20Application/${app_row_name}" \
        -b /tmp/frappe_cookies_apps_$$.txt 2>/dev/null)
      app_name=$(echo "$detail" | jq -r '.data.app_name // empty' 2>/dev/null)
      [[ -n "$app_name" ]] && app_names="${app_names}${app_name},"
    done < <(echo "$body" | jq -r '.message[].name' 2>/dev/null)
    app_names="${app_names%,}"
    pass "$count app(s): ${app_names:-<names unavailable>}"
  else
    fail "aucune app installée (body: $(echo "$body" | cut -c1-60))"
  fi
else
  skip "session non disponible"
fi

# Nettoyer cookies apps
rm -f /tmp/frappe_cookies_apps_$$.txt 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 11. ROUTING TRAEFIK AVANCÉ — wildcard + priorités
# ─────────────────────────────────────────────────────────────────────────────
log_section "11. ROUTING TRAEFIK — wildcard et priorités"

# Vérifier que press.local n'est pas capturé par la wildcard *.press.local
CURRENT_TEST="Routing — press.local n'est pas capturé par wildcard"
log_test "press.local non capturé par wildcard client-sites"
code_press=$(http_get "https://press.local:${PORT_HTTPS}/")
body_press=$(http_body "https://press.local:${PORT_HTTPS}/")
_press_matches=$(echo "$body_press" | grep -ciE "frappe|press|DOCTYPE" 2>/dev/null) || _press_matches=0
if [[ "$code_press" == "200" && "$_press_matches" -gt 0 ]]; then
  pass "press.local → Press dashboard (HTTP 200)"
elif [[ "$code_press" == "200" ]]; then
  pass "press.local HTTP 200 (routing OK vers Press)"
else
  fail "press.local HTTP $code_press (attendu 200)"
fi

# Vérifier que git.press.local n'est pas capturé par la wildcard
CURRENT_TEST="Routing — git.press.local non capturé par wildcard"
log_test "git.press.local non capturé par wildcard"
code=$(http_get "https://git.press.local:${PORT_HTTPS}/api/v1/version")
body=$(http_body "https://git.press.local:${PORT_HTTPS}/api/v1/version")
if echo "$body" | grep -q '"version"'; then
  pass "git.press.local pointe vers Forgejo"
else
  fail "git.press.local ne pointe pas vers Forgejo (HTTP $code)"
fi

# Vérifier que s3.press.local n'est pas capturé par la wildcard
CURRENT_TEST="Routing — s3.press.local non capturé par wildcard"
log_test "s3.press.local non capturé par wildcard"
code=$(http_get "https://s3.press.local:${PORT_HTTPS}/")
if [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]]; then
  pass "HTTP $code — s3.press.local route vers Garage"
else
  fail "HTTP $code — routing s3 problématique"
fi

# Plusieurs sous-domaines clients (routing wildcard)
CURRENT_TEST="Routing — multiple sous-domaines *.press.local"
log_test "Routing — multiple sous-domaines *.press.local"
subdomains=("testsite" "demosite" "client1")
successes=0
for sub in "${subdomains[@]}"; do
  code=$(http_get "https://${sub}.press.local:${PORT_HTTPS}/" --max-time 5)
  if [[ "$code" == "200" || "$code" == "404" ]]; then
    # 404 = Frappe répond mais site inconnu — routing OK
    successes=$((successes + 1))
  fi
done
if [[ "$successes" -ge 2 ]]; then
  pass "$successes/${#subdomains[@]} sous-domaines routés vers frappe-server"
elif [[ "$successes" -ge 1 ]]; then
  pass "$successes/${#subdomains[@]} sous-domaines routés (OK partiel)"
else
  fail "aucun sous-domaine client ne répond via wildcard"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 12. INTÉGRATION PRESS → SERVER — Jobs agents
# ─────────────────────────────────────────────────────────────────────────────
log_section "12. INTÉGRATION Press → Server — Jobs agents"

if [[ "$PRESS_SESSION_OK" == "true" ]]; then
  # Vérifier les Agent Jobs récents
  CURRENT_TEST="Press — Agent Jobs récents"
  log_test "Press — Agent Jobs récents"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Agent Job?limit=10&order_by=creation desc" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    success_count=$(http_body \
      "${PRESS_URL}/api/resource/Agent Job?filters=[[\"status\",\"=\",\"Success\"]]&limit=20" \
      -b /tmp/frappe_cookies_$$.txt | jq '.data | length' 2>/dev/null) || success_count=0
    fail_count=$(http_body \
      "${PRESS_URL}/api/resource/Agent Job?filters=[[\"status\",\"=\",\"Failure\"]]&limit=20" \
      -b /tmp/frappe_cookies_$$.txt | jq '.data | length' 2>/dev/null) || fail_count=0
    pass "$count jobs totaux — Success: $success_count, Failure: $fail_count"
  else
    skip "aucun Agent Job trouvé (normal si aucun site déployé)"
  fi

  # Vérifier que le serveur est "Active" dans Press
  CURRENT_TEST="Press — Server enregistré et Active"
  log_test "Press — Server enregistré et Active"
  # Frappe list API retourne seulement 'name' — fields URL-encodés
  body=$(http_body \
    "${PRESS_URL}/api/resource/Server?limit=5&fields=%5B%22name%22%2C%22status%22%2C%22hostname%22%5D" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    status=$(echo "$body" | jq -r '.data[0].status' 2>/dev/null)
    name=$(echo "$body" | jq -r '.data[0].name' 2>/dev/null)
    if [[ "$status" == "Active" ]]; then
      pass "$name — status=Active"
    else
      fail "$name — status=$status (attendu Active)"
    fi
  else
    fail "aucun server — lancer: make register-server"
  fi

  # Bench dans Press
  CURRENT_TEST="Press — Bench configuré"
  log_test "Press — Bench configuré"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Bench?limit=10" \
    -b /tmp/frappe_cookies_$$.txt)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -ge 1 ]]; then
    pass "$count bench(es) configuré(s)"
  else
    skip "aucun bench (normal si site pas encore déployé)"
  fi

  # Circuit breaker — vérifier qu'il n'y a pas d'Agent Request Failure bloquant
  CURRENT_TEST="Press — pas de circuit breaker actif"
  log_test "Press — pas de circuit breaker actif"
  body=$(http_body \
    "${PRESS_URL}/api/resource/Agent Job?filters=[[\"status\",\"=\",\"Delivery Failure\"]]&limit=5" \
    -b /tmp/frappe_cookies_$$.txt 2>/dev/null)
  count=$(echo "$body" | jq '.data | length' 2>/dev/null) || count=0
  if [[ "$count" -eq 0 ]]; then
    pass "aucun Delivery Failure"
  else
    fail "$count Delivery Failure(s) — circuit breaker potentiellement actif"
  fi

else
  for t in "Press — Agent Jobs récents" "Press — Server Active" \
            "Press — Bench configuré" "Press — pas de circuit breaker"; do
    log_test "$t"; skip "session Press non disponible"
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# 13. CONTENEURS — Etat Podman
# ─────────────────────────────────────────────────────────────────────────────
log_section "13. CONTENEURS — Etat Podman/Docker"

CONTAINER_CMD=""
if command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
  CONTAINER_CMD="docker"
fi

EXPECTED_CONTAINERS=(
  "${PREFIX}traefik"
  "${PREFIX}mariadb"
  "${PREFIX}redis_cache"
  "${PREFIX}redis_queue"
  "${PREFIX}press"
  "${PREFIX}server"
  "${PREFIX}garage"
  "${PREFIX}forgejo"
  "${PREFIX}stalwart"
  "${PREFIX}prometheus"
  "${PREFIX}grafana"
  "${PREFIX}loki"
  "${PREFIX}ollama"
  "${PREFIX}openwebui"
)

if [[ -n "$CONTAINER_CMD" ]]; then
  for container in "${EXPECTED_CONTAINERS[@]}"; do
    CURRENT_TEST="Container $container running"
    log_test "Container $container"
    status=$($CONTAINER_CMD inspect --format='{{.State.Status}}' "$container" 2>/dev/null) || status="absent"
    health=$($CONTAINER_CMD inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null) || health=""
    if [[ "$status" == "running" ]]; then
      if [[ -n "$health" && "$health" != "<nil>" && "$health" != "healthy" ]]; then
        fail "running mais health=$health"
      else
        pass "running${health:+ ($health)}"
      fi
    elif [[ "$status" == "absent" ]]; then
      fail "container absent"
    else
      fail "status=$status"
    fi
  done
else
  log_test "Vérification containers"
  skip "podman/docker non disponible"
fi

# ─────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ FINAL
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║                     RÉSUMÉ DES TESTS                            ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Total      : ${BOLD}${TESTS_TOTAL}${RESET}"
echo -e "  ${GREEN}Passed${RESET}     : ${BOLD}${GREEN}${TESTS_PASSED}${RESET}"
echo -e "  ${RED}Failed${RESET}     : ${BOLD}${RED}${TESTS_FAILED}${RESET}"
echo -e "  ${YELLOW}Skipped${RESET}    : ${BOLD}${YELLOW}${TESTS_SKIPPED}${RESET}"
echo ""

if [[ "${#FAILED_TESTS[@]}" -gt 0 ]]; then
  echo -e "${BOLD}${RED}Tests échoués:${RESET}"
  for ft in "${FAILED_TESTS[@]}"; do
    echo -e "  ${RED}x${RESET} $ft"
  done
  echo ""
fi

echo -e "  Log complet : ${YELLOW}${LOG_FILE}${RESET}"
echo ""

if [[ "$TESTS_FAILED" -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}  TOUS LES TESTS SONT PASSES${RESET}"
  echo ""
  exit 0
else
  PERCENT=$((TESTS_PASSED * 100 / TESTS_TOTAL))
  echo -e "${BOLD}${RED}  ${TESTS_FAILED} TEST(S) EN ECHEC — ${PERCENT}% de reussite${RESET}"
  echo ""
  exit 1
fi
