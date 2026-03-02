#!/usr/bin/env bash
# quadlets/install.sh — Installe les Quadlets Presse Claude dans ~/.config/containers/systemd/
#
# Usage:
#   ./quadlets/install.sh              # installe tous les tiers
#   ./quadlets/install.sh --tier core  # installe seulement tier0
#   ./quadlets/install.sh --check      # vérifie la configuration sans installer
#
# Profils de ressources:
#   small  (8-16 Go)  → tier0-core + tier1-press (6 services)
#   medium (16-32 Go) → + tier2-devtools          (9 services)
#   large  (32-64 Go) → + tier3-observability    (12 services)
#   gpu    (64 Go+)   → + tier4-ai               (14 services)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QUADLET_DIR="$HOME/.config/containers/systemd/presse-claude"

# ── Détection des ressources ──────────────────────────────────────────────────
detect_profile() {
  local total_ram_gb
  total_ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)

  # Détection GPU AMD
  local has_gpu=false
  if ls /dev/dri/renderD* 2>/dev/null | grep -q renderD; then
    has_gpu=true
  fi

  if [[ "$has_gpu" == "true" ]] && [[ "$total_ram_gb" -ge 32 ]]; then
    echo "gpu"
  elif [[ "$total_ram_gb" -ge 32 ]]; then
    echo "large"
  elif [[ "$total_ram_gb" -ge 16 ]]; then
    echo "medium"
  else
    echo "small"
  fi
}

# ── Parsing arguments ─────────────────────────────────────────────────────────
PROFILE=""
TIER=""
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)  PROFILE="$2";   shift 2 ;;
    --tier)     TIER="$2";      shift 2 ;;
    --check)    CHECK_ONLY=true; shift  ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "Option inconnue: $1"; exit 1 ;;
  esac
done

# Auto-détection si profil non spécifié
if [[ -z "$PROFILE" && -z "$TIER" ]]; then
  PROFILE=$(detect_profile)
  echo "==> Profil détecté automatiquement: $PROFILE"
fi

# ── Prérequis ─────────────────────────────────────────────────────────────────
check_prerequisites() {
  echo "==> Vérification des prérequis..."

  # Podman
  if ! command -v podman &>/dev/null; then
    echo "ERREUR: podman non trouvé"
    exit 1
  fi
  echo "    ✓ podman $(podman --version | awk '{print $3}')"

  # systemd --user
  if ! systemctl --user status &>/dev/null; then
    echo "ERREUR: systemd --user non disponible (nécessite loginctl enable-linger $USER)"
    exit 1
  fi
  echo "    ✓ systemd --user disponible"

  # Quadlet generator
  local quadlet_gen
  quadlet_gen="$(podman info --format '{{.Host.BuildahVersion}}' 2>/dev/null || true)"
  if [[ ! -x "/usr/libexec/podman/quadlet" ]]; then
    echo "AVERTISSEMENT: /usr/libexec/podman/quadlet non trouvé (Podman < 4.4 ?)"
  else
    echo "    ✓ Quadlet generator disponible"
  fi

  # Socket Podman rootless
  local socket_path="$XDG_RUNTIME_DIR/podman/podman.sock"
  if [[ ! -S "$socket_path" ]]; then
    echo "AVERTISSEMENT: Socket Podman non trouvé: $socket_path"
    echo "             Lancer: systemctl --user enable --now podman.socket"
  else
    echo "    ✓ Socket Podman: $socket_path"
  fi

  # Linger (requis pour démarrage au boot sans session)
  if loginctl show-user "$USER" | grep -q 'Linger=yes'; then
    echo "    ✓ loginctl linger activé"
  else
    echo "AVERTISSEMENT: loginctl linger désactivé — services arrêtés à la déconnexion"
    echo "             Activer: loginctl enable-linger $USER"
  fi

  # Images locales
  for img in presse_claude_press:latest presse_claude_server:latest; do
    if podman image exists "$img"; then
      echo "    ✓ Image locale: $img"
    else
      echo "AVERTISSEMENT: Image manquante: $img → make build"
    fi
  done
}

# ── Installation ──────────────────────────────────────────────────────────────
install_tier() {
  local tier="$1"
  local src="$SCRIPT_DIR/$tier"
  local dst="$QUADLET_DIR/$tier"

  if [[ ! -d "$src" ]]; then
    echo "    ⚠ Tier non trouvé: $src"
    return
  fi

  mkdir -p "$dst"
  cp -v "$src"/*.container "$dst"/ 2>/dev/null || true
  cp -v "$src"/*.target    "$dst"/ 2>/dev/null || true
  echo "    ✓ $tier installé"
}

install_quadlets() {
  echo "==> Installation dans: $QUADLET_DIR"
  mkdir -p "$QUADLET_DIR"

  # Réseau + volumes (toujours nécessaires)
  mkdir -p "$QUADLET_DIR/networks" "$QUADLET_DIR/volumes"
  cp -v "$SCRIPT_DIR/networks"/*.network "$QUADLET_DIR/networks/" 2>/dev/null || true
  cp -v "$SCRIPT_DIR/volumes"/*.volume   "$QUADLET_DIR/volumes/"  2>/dev/null || true

  # IMPORTANT: Les .target sont des units systemd natifs → ~/.config/systemd/user/
  # (pas dans ~/.config/containers/systemd/ qui est réservé au générateur Quadlet)
  local systemd_user_dir="$HOME/.config/systemd/user"
  mkdir -p "$systemd_user_dir"
  cp -v "$SCRIPT_DIR/targets"/*.target "$systemd_user_dir/" 2>/dev/null || true
  echo "    ✓ targets systemd installés dans $systemd_user_dir"

  # Tiers selon profil
  case "${TIER:-$PROFILE}" in
    core)
      install_tier tier0-core
      ;;
    small)
      install_tier tier0-core
      install_tier tier1-press
      ;;
    medium)
      install_tier tier0-core
      install_tier tier1-press
      install_tier tier2-devtools
      ;;
    large)
      install_tier tier0-core
      install_tier tier1-press
      install_tier tier2-devtools
      install_tier tier3-observability
      ;;
    gpu|full)
      install_tier tier0-core
      install_tier tier1-press
      install_tier tier2-devtools
      install_tier tier3-observability
      install_tier tier4-ai
      ;;
    *)
      echo "==> Installation complète (tous les tiers)"
      for tier in tier0-core tier1-press tier2-devtools tier3-observability tier4-ai; do
        install_tier "$tier"
      done
      ;;
  esac

  echo ""
  echo "==> Rechargement du daemon systemd --user..."
  systemctl --user daemon-reload

  echo ""
  echo "==> Quadlets installés. Vérification:"
  systemctl --user list-unit-files 'presse-claude-*' 2>/dev/null | head -30 || true

  echo ""
  echo "Prochaines étapes:"
  echo "  make quadlets-start-${TIER:-$PROFILE}   # démarrer les services"
  echo "  systemctl --user status presse-claude-*  # état des services"
  echo "  journalctl --user -u presse-claude-*     # logs"
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Presse Claude — Installation Quadlets Podman        ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

check_prerequisites

if [[ "$CHECK_ONLY" == "true" ]]; then
  echo ""
  echo "==> Mode vérification uniquement — aucun fichier modifié."
  exit 0
fi

echo ""
install_quadlets

echo ""
echo "✓ Installation terminée!"
