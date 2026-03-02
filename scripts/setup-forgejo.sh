#!/bin/bash
# scripts/setup-forgejo.sh — Crée l'admin Forgejo et les repos des apps Frappe
# Usage: ./scripts/setup-forgejo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

# Lecture sécurisée des variables depuis .env (évite les clés SSH multi-lignes)
get_env() {
  grep -m1 "^${1}=" "${ENV_FILE}" | cut -d= -f2-
}

PORT_FORGEJO_HTTP="$(get_env PORT_FORGEJO_HTTP)"
FORGEJO_ADMIN_USER="$(get_env FORGEJO_ADMIN_USER)"
FORGEJO_ADMIN_PASSWORD="$(get_env FORGEJO_ADMIN_PASSWORD)"
FORGEJO_ADMIN_EMAIL="$(get_env FORGEJO_ADMIN_EMAIL)"
PREFIX="$(get_env PREFIX)"
DOMAIN="$(get_env DOMAIN)"

FORGEJO_URL="http://127.0.0.1:${PORT_FORGEJO_HTTP}"
API="${FORGEJO_URL}/api/v1"
ADMIN="${FORGEJO_ADMIN_USER}"
PASS="${FORGEJO_ADMIN_PASSWORD}"

echo "=== Configuration Forgejo ==="

# Attendre Forgejo
echo "→ Attente de Forgejo..."
for i in {1..30}; do
  if curl -sf "${FORGEJO_URL}/api/healthz" >/dev/null 2>&1; then
    echo "  Forgejo prêt."
    break
  fi
  sleep 3
  echo -n "."
done
echo ""

# Créer l'admin via CLI Docker (exécuté en tant qu'utilisateur git)
# Note: le nom 'admin' est réservé dans Forgejo, utiliser un autre nom (ex: gitadmin)
echo "→ Création du compte admin (${ADMIN})..."
podman exec -u git "${PREFIX}forgejo" forgejo admin user create \
  --username "${ADMIN}" \
  --password "${PASS}" \
  --email "${FORGEJO_ADMIN_EMAIL}" \
  --admin \
  --must-change-password=false \
  --config /data/gitea/conf/app.ini 2>&1 || echo "  Admin déjà existant ou erreur ignorée"

# Créer l'organisation 'frappe' pour grouper les apps
echo "→ Création de l'organisation 'frappe'..."
curl -sf -X POST "${API}/orgs" \
  -u "${ADMIN}:${PASS}" \
  -H "Content-Type: application/json" \
  -d '{"username":"frappe","visibility":"public","repo_admin_change_team_access":true}' \
  >/dev/null 2>&1 || echo "  Organisation 'frappe' déjà existante"

# Créer les repos des apps Frappe principales (miroirs des repos GitHub)
APPS=(
  "frappe"
  "erpnext"
  "hrms"
  "crm"
  "helpdesk"
  "lms"
  "drive"
  "insights"
  "wiki"
  "gameplan"
  "press"
)

for APP in "${APPS[@]}"; do
  echo "→ Repo: frappe/${APP}"
  curl -sf -X POST "${API}/orgs/frappe/repos" \
    -u "${ADMIN}:${PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${APP}\",\"description\":\"Frappe ${APP} app\",\"private\":false,\"auto_init\":false}" \
    >/dev/null 2>&1 || echo "  Repo ${APP} déjà existant"
done

echo ""
echo "Forgejo configuré."
echo "  URL: https://git.${DOMAIN}"
echo "  Login: ${ADMIN}"
echo ""
echo "Repos créés sous l'organisation 'frappe':"
for APP in "${APPS[@]}"; do
  echo "  → https://git.${DOMAIN}/frappe/${APP}"
done
echo ""
echo "Note: Pour utiliser ces repos dans Press, configurer:"
echo "  Press Settings > Git URL: https://git.${DOMAIN}"
