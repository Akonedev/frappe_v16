#!/bin/bash
# scripts/setup-press.sh — Configure Press Settings après démarrage
# Usage: ./scripts/setup-press.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_DIR}/.env"

BENCH="podman exec ${PREFIX}press bench"
SITE="${PRESS_SITE_NAME}"

echo "=== Configuration Press Settings ==="

# Vérifier que Press est prêt
echo "→ Vérification que Press est prêt..."
for i in {1..20}; do
  if podman exec "${PREFIX}press" curl -sf http://localhost:8000/api/method/frappe.ping >/dev/null 2>&1; then
    echo "  Press prêt."
    break
  fi
  echo -n "."
  sleep 10
done

# Configurer Press Settings via frappe execute
podman exec "${PREFIX}press" bash -c "
cd /home/frappe/frappe-bench
bench --site ${SITE} execute press.press.doctype.press_settings.press_settings.setup_config << 'PYEOF'
import frappe
frappe.db.set_value('Press Settings', None, {
    'domain': '${DOMAIN}',
    'dns_provider': 'Generic',
    'server_provider': 'Generic',
    'backup_s3_bucket': '${GARAGE_BUCKET_BACKUPS}',
    'offsite_backups_access_key_id': '${GARAGE_ACCESS_KEY}',
    'offsite_backups_secret_access_key': '${GARAGE_SECRET_KEY}',
    'backup_s3_endpoint_url': 'http://${PREFIX}garage:3900',
    'smtp_server': '${PREFIX}stalwart',
})
frappe.db.commit()
print('Press Settings configuré.')
PYEOF
" 2>/dev/null || echo "  Note: Configuration manuelle requise dans l'interface Press"

echo ""
echo "✓ Press configuré."
echo "  Dashboard: https://${DOMAIN}"
echo "  Email: ${PRESS_ADMIN_EMAIL}"
