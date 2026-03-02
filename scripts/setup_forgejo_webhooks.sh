#!/bin/bash
set -uo pipefail
# setup_forgejo_webhooks.sh — Configure les webhooks Forgejo → Press
# Crée un webhook sur chaque repo Forgejo pour notifier Press à chaque push.
# Usage: ./scripts/setup_forgejo_webhooks.sh
#
# La variable WEBHOOK_SECRET doit correspondre à github_webhook_secret
# dans Press Settings (Press Admin → Press Settings → github_webhook_secret).

# Charger les variables depuis .env si disponible
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"

# Valeurs par défaut
WEBHOOK_SECRET="${PRESS_WEBHOOK_SECRET:-presse_webhook_2024_3338603870487f60}"
PORT_FORGEJO="${PORT_FORGEJO:-14050}"
FORGEJO_URL="http://127.0.0.1:${PORT_FORGEJO}"
FORGEJO_ADMIN="${FORGEJO_ADMIN_USER:-gitadmin}"
FORGEJO_PASS="${FORGEJO_ADMIN_PASSWORD:-presse_admin_2024}"
FORGEJO_CREDS="${FORGEJO_ADMIN}:${FORGEJO_PASS}"
PREFIX="${PREFIX:-presse_claude_}"
PRESS_WEBHOOK_URL="http://${PREFIX}press:8000/api/method/press.api.forgejo.hook"

REPOS=(
  "frappe/frappe"
  "frappe/erpnext"
  "frappe/hrms"
  "frappe/crm"
  "frappe/helpdesk"
  "frappe/lms"
  "frappe/wiki"
  "frappe/gameplan"
  "frappe/builder"
  "frappe/print_designer"
  "frappe/payments"
  "frappe/drive"
  "frappe/insights"
  "The-Commit-Company/raven"
  "frappe/mail"
)

created=0
skipped=0
errors=0

for REPO_PATH in "${REPOS[@]}"; do
  OWNER=$(echo "$REPO_PATH" | cut -d'/' -f1)
  REPO=$(echo "$REPO_PATH" | cut -d'/' -f2)

  # Vérifier si le repo existe dans Forgejo
  REPO_STATUS=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
    -u "${FORGEJO_CREDS}" \
    "${FORGEJO_URL}/api/v1/repos/${OWNER}/${REPO}")

  if [ "$REPO_STATUS" != "200" ]; then
    echo "SKIP: ${REPO_PATH} (repo inexistant HTTP $REPO_STATUS)"
    skipped=$((skipped+1))
    continue
  fi

  # Vérifier si webhook existe déjà
  EXISTING=$(curl -s --max-time 30 -u "${FORGEJO_CREDS}" \
    "${FORGEJO_URL}/api/v1/repos/${OWNER}/${REPO}/hooks" 2>/dev/null | \
    python3 -c "
import sys,json
try:
    hooks=json.load(sys.stdin)
    print(any('press.api.forgejo' in h.get('config',{}).get('url','') for h in hooks))
except:
    print('False')
" 2>/dev/null)

  if [ "$EXISTING" = "True" ]; then
    echo "SKIP: ${REPO_PATH} (webhook déjà configuré)"
    skipped=$((skipped+1))
    continue
  fi

  # Créer le webhook
  HTTP_CODE=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' \
    -u "${FORGEJO_CREDS}" \
    -X POST \
    -H "Content-Type: application/json" \
    "${FORGEJO_URL}/api/v1/repos/${OWNER}/${REPO}/hooks" \
    -d "{
      \"type\": \"gitea\",
      \"config\": {
        \"url\": \"${PRESS_WEBHOOK_URL}\",
        \"content_type\": \"json\",
        \"secret\": \"${WEBHOOK_SECRET}\"
      },
      \"events\": [\"push\"],
      \"active\": true
    }" 2>/dev/null)

  if [ "$HTTP_CODE" = "201" ]; then
    echo "OK: ${REPO_PATH}"
    created=$((created+1))
  else
    echo "ERROR: ${REPO_PATH} (HTTP $HTTP_CODE)"
    errors=$((errors+1))
  fi
done

echo ""
echo "=== Résumé: $created créés, $skipped ignorés, $errors erreurs ==="
