#!/bin/bash
# scripts/setup-mkcert.sh
# Génère des certificats TLS locaux de confiance pour *.press.local via mkcert
# Les certs sont montés dans Traefik via config/traefik/certs/
# Usage: ./scripts/setup-mkcert.sh

set -euo pipefail

CERTS_DIR="$(dirname "$0")/../config/traefik/certs"
CAROOT="${CERTS_DIR}/ca"

mkdir -p "$CERTS_DIR"

# Installer mkcert si absent
if ! command -v mkcert &>/dev/null; then
    MKCERT_BIN="$HOME/.local/bin/mkcert"
    mkdir -p "$HOME/.local/bin"
    echo "→ Téléchargement de mkcert..."
    curl -L https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64 \
        -o "$MKCERT_BIN" 2>/dev/null
    chmod +x "$MKCERT_BIN"
    export PATH="$HOME/.local/bin:$PATH"
fi

echo "=== Génération des certificats mkcert pour press.local ==="

# Créer/utiliser la CA locale
CAROOT="$CAROOT" mkcert -install 2>/dev/null || true

# Générer le certificat wildcard
CAROOT="$CAROOT" mkcert \
    -cert-file "$CERTS_DIR/press.local.crt" \
    -key-file  "$CERTS_DIR/press.local.key" \
    "press.local" \
    "*.press.local" \
    "localhost" \
    "127.0.0.1"

echo ""
echo "✓ Certificats générés dans config/traefik/certs/"
echo "  cert: press.local.crt"
echo "  key:  press.local.key"
echo "  ca:   ca/rootCA.pem"
echo ""
echo "→ Redémarrer Traefik pour appliquer:"
echo "  podman-compose -f podman-compose.yml --env-file .env restart presse_claude_traefik"
echo ""
echo "→ Installer la CA dans Firefox/Chrome (si pas fait automatiquement):"
echo "  mkcert -install"
echo "  (ou importer ca/rootCA.pem dans les paramètres navigateur)"
