#!/bin/bash
# scripts/dns-setup.sh — Ajoute les entrées DNS locales pour press.local dans /etc/hosts
# Usage: ./scripts/dns-setup.sh

set -euo pipefail

# Charger .env depuis la racine du projet
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_DIR}/.env"

HOSTS_FILE="/etc/hosts"
MARKER_START="# === presse_claude START ==="
MARKER_END="# === presse_claude END ==="
IP="127.0.0.1"

# Vérifier si déjà configuré
if grep -q "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
  echo "DNS ${DOMAIN} déjà configuré dans ${HOSTS_FILE}."
  echo "Entrées existantes:"
  sed -n "/$MARKER_START/,/$MARKER_END/p" "$HOSTS_FILE"
  exit 0
fi

echo "Ajout des entrées DNS dans ${HOSTS_FILE} (sudo requis)..."

sudo tee -a "$HOSTS_FILE" > /dev/null << EOF

${MARKER_START}
${IP} ${DOMAIN}
${IP} traefik.${DOMAIN}
${IP} git.${DOMAIN}
${IP} s3.${DOMAIN}
${IP} monitor.${DOMAIN}
${IP} mail.${DOMAIN}
${IP} ai.${DOMAIN}
${IP} apps.${DOMAIN}
${MARKER_END}
EOF

echo ""
echo "✓ DNS ${DOMAIN} configuré."
echo "  → https://${DOMAIN} (Press dashboard)"
echo "  → https://git.${DOMAIN} (Forgejo)"
echo "  → https://s3.${DOMAIN} (Garage S3)"
echo "  → https://monitor.${DOMAIN} (Grafana)"
echo "  → https://mail.${DOMAIN} (Stalwart)"
echo "  → https://ai.${DOMAIN} (Open WebUI)"
echo "  → https://traefik.${DOMAIN} (Traefik dashboard)"
echo "  → https://apps.${DOMAIN} (Apps demo site)"
