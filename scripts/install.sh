#!/bin/bash
# scripts/install.sh — Installation guidée complète de Presse Claude
# Usage: ./scripts/install.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "${PROJECT_DIR}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      PRESSE CLAUDE — Installation complète          ║"
echo "║      Frappe Press SaaS Platform (dev local)         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Prérequis ────────────────────────────────────────────────────────────────
step "Vérification des prérequis"
command -v podman >/dev/null 2>&1 || error "Podman non installé"
command -v podman-compose >/dev/null 2>&1 || error "podman-compose non installé (pip3 install podman-compose)"
command -v git >/dev/null 2>&1 || error "Git non installé"
info "Podman: $(podman --version)"
info "podman-compose: $(podman-compose version 2>/dev/null | head -1)"

# ── Fichier .env ─────────────────────────────────────────────────────────────
step "Configuration"
if [ ! -f ".env" ]; then
  cp .env.example .env
  warn ".env créé depuis .env.example"
  warn "MODIFIEZ LES MOTS DE PASSE dans .env avant de continuer!"
  warn "Puis relancez: make install"
  exit 0
fi
source .env
info "Configuration: ${DOMAIN} (prefix: ${PREFIX})"

# ── SSH Keys ─────────────────────────────────────────────────────────────────
step "Clés SSH Press→Server"
./scripts/generate-ssh-keys.sh

# ── DNS ──────────────────────────────────────────────────────────────────────
step "DNS local (${DOMAIN})"
./scripts/dns-setup.sh || warn "DNS setup nécessite un sudo interactif. Exécuter manuellement: ./scripts/dns-setup.sh"

# ── Infrastructure ────────────────────────────────────────────────────────────
step "Infrastructure (MariaDB, Redis, Traefik)"
podman-compose -f podman-compose.yml --env-file .env up -d mariadb redis-cache redis-queue traefik

info "Attente que MariaDB soit prêt..."
for i in {1..30}; do
  if podman exec "${PREFIX}mariadb" mysqladmin ping -u root -p"${MARIADB_ROOT_PASSWORD}" -h localhost --silent 2>/dev/null; then
    info "MariaDB prêt."
    break
  fi
  sleep 3
done

# ── Garage S3 ─────────────────────────────────────────────────────────────────
step "Garage S3"
podman-compose -f podman-compose.yml --env-file .env up -d garage
sleep 10
./scripts/setup-garage.sh

# ── Server container ──────────────────────────────────────────────────────────
step "Container server (Ubuntu+SSH)"
podman-compose -f podman-compose.yml --env-file .env build server
podman-compose -f podman-compose.yml --env-file .env up -d server
sleep 15

# ── Press ─────────────────────────────────────────────────────────────────────
step "Frappe Press"
podman-compose -f podman-compose.yml --env-file .env build press
podman-compose -f podman-compose.yml --env-file .env up -d press

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Frappe Press démarre en arrière-plan.              ║"
echo "║  Première initialisation: ~20-30 minutes.           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Surveiller le progrès:"
echo "  podman-compose -f podman-compose.yml --env-file .env logs -f press"
echo ""
echo "Quand prêt (bench serve démarré):"
echo "  ./scripts/setup-press.sh     # Configurer Press Settings"
echo "  ./scripts/register-server.sh # Enregistrer le server"
echo ""
echo "  Dashboard: https://${DOMAIN}"
echo "  Login:     ${PRESS_ADMIN_EMAIL}"
