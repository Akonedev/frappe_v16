#!/bin/bash
# scripts/register-server.sh — Enregistre le container server dans Frappe Press
# Usage: ./scripts/register-server.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_DIR}/.env"

echo "=== Enregistrement du Server Container dans Press ==="

# Récupérer l'IP interne du container server
SERVER_IP=$(podman inspect "${PREFIX}server" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)

if [ -z "${SERVER_IP}" ]; then
  echo "ERREUR: Container ${PREFIX}server non trouvé ou pas démarré."
  exit 1
fi

echo "→ Server IP interne: ${SERVER_IP}"
echo "→ Server SSH port externe: ${PORT_SERVER_SSH}"

# ── Injecter la clé publique Press dans le server ──────────────────────────
PUBLIC_KEY_FILE="${PROJECT_DIR}/data/ssh/press_id_rsa.pub"
if [ ! -f "${PUBLIC_KEY_FILE}" ]; then
  echo "ERREUR: Clé publique non trouvée: ${PUBLIC_KEY_FILE}"
  echo "  Exécuter d'abord: ./scripts/generate-ssh-keys.sh"
  exit 1
fi

PUBLIC_KEY=$(cat "${PUBLIC_KEY_FILE}")
echo "→ Injection de la clé publique Press dans le server..."

podman exec "${PREFIX}server" bash -c "
  mkdir -p /home/frappe/.ssh
  # Éviter les doublons
  if ! grep -qF '${PUBLIC_KEY}' /home/frappe/.ssh/authorized_keys 2>/dev/null; then
    echo '${PUBLIC_KEY}' >> /home/frappe/.ssh/authorized_keys
  fi
  chmod 700 /home/frappe/.ssh
  chmod 600 /home/frappe/.ssh/authorized_keys
  chown -R frappe:frappe /home/frappe/.ssh
"

echo "✓ Clé SSH injectée."

# ── Tester la connexion SSH ──────────────────────────────────────────────────
echo "→ Test de connexion SSH Press→Server..."
PRIVATE_KEY="${PROJECT_DIR}/data/ssh/press_id_rsa"

if ssh -i "${PRIVATE_KEY}" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=10 \
       -p "${PORT_SERVER_SSH}" \
       frappe@127.0.0.1 \
       "echo 'SSH OK'" 2>/dev/null; then
  echo "✓ Connexion SSH opérationnelle."
else
  echo "AVERTISSEMENT: Connexion SSH échouée. Vérifier que ${PREFIX}server est démarré."
fi

# ── Informations pour enregistrement manuel dans Press ──────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Enregistrement manuel du server dans Press UI       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  1. Ouvrir https://${DOMAIN}"
echo "  2. Infrastructure > Servers > New Server"
echo "  3. Renseigner:"
echo "     - Hostname : server.press.local"
echo "     - IP       : ${SERVER_IP}"
echo "     - SSH Port : 22 (port interne Docker)"
echo "     - SSH User : frappe"
echo "  4. Save → Press va provisionner le server via Ansible"
echo ""
echo "✓ Script terminé."
