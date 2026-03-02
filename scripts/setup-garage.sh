#!/bin/bash
# scripts/setup-garage.sh — Configure Garage S3: layout, clés, buckets
# Usage: ./scripts/setup-garage.sh
#
# NOTE: Garage v1.x génère ses propres Access Key ID (format GKxxx).
# Après la première exécution, les credentials réels sont affichés et doivent
# être reportés dans .env (GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_DIR}/.env"

GARAGE="podman exec ${PREFIX}garage /garage"

echo "=== Configuration Garage S3 ==="

# Attendre que Garage soit prêt
echo "→ Attente de Garage..."
for i in {1..30}; do
  if $GARAGE status >/dev/null 2>&1; then
    echo "  Garage prêt."
    break
  fi
  sleep 2
  echo -n "."
done

# Récupérer le Node ID (format court : 16 premiers caractères)
NODE_ID=$($GARAGE node id 2>/dev/null | grep -oE '[0-9a-f]{16,}' | head -1 | cut -c1-16)
if [ -z "$NODE_ID" ]; then
  echo "ERREUR: Impossible de récupérer le Node ID de Garage"
  exit 1
fi
echo "→ Node ID: ${NODE_ID}"

# Configurer le layout (zone dc1, capacité 1GB en dev)
echo "→ Configuration du layout..."
LAYOUT_STATUS=$($GARAGE status 2>/dev/null | grep "NO ROLE ASSIGNED" || true)
if [ -n "$LAYOUT_STATUS" ]; then
  $GARAGE layout assign -z dc1 -c 1G "${NODE_ID}" 2>/dev/null
  $GARAGE layout apply --version 1 2>/dev/null && echo "  Layout appliqué." || echo "  Layout déjà à jour."
else
  echo "  Layout déjà configuré."
fi

# Créer la clé d'accès S3 si elle n'existe pas encore
echo "→ Création de la clé d'accès S3..."
EXISTING_KEY=$($GARAGE key list 2>/dev/null | grep "press-key" || true)
if [ -z "$EXISTING_KEY" ]; then
  echo "  Création d'une nouvelle clé press-key..."
  KEY_INFO=$($GARAGE key create press-key 2>/dev/null)
  GENERATED_KEY_ID=$(echo "$KEY_INFO" | grep "Key ID:" | awk '{print $3}')
  GENERATED_SECRET=$(echo "$KEY_INFO" | grep "Secret key:" | awk '{print $3}')
  echo "  Key ID:     ${GENERATED_KEY_ID}"
  echo "  Secret key: ${GENERATED_SECRET}"
  echo ""
  echo "  IMPORTANT: Mettez à jour .env avec ces credentials :"
  echo "  GARAGE_ACCESS_KEY=${GENERATED_KEY_ID}"
  echo "  GARAGE_SECRET_KEY=${GENERATED_SECRET}"
  ACTUAL_KEY_ID="${GENERATED_KEY_ID}"
else
  echo "  Clé press-key déjà existante."
  ACTUAL_KEY_ID=$($GARAGE key list 2>/dev/null | grep "press-key" | awk '{print $1}')
fi

# Créer les buckets et assigner les permissions
for BUCKET in "${GARAGE_BUCKET_BACKUPS}" "${GARAGE_BUCKET_UPLOADS}"; do
  echo "→ Bucket: ${BUCKET}"
  $GARAGE bucket create "${BUCKET}" 2>/dev/null && echo "  Bucket ${BUCKET} créé." || echo "  Bucket ${BUCKET} déjà existant."
  $GARAGE bucket allow \
    --read --write --owner \
    "${BUCKET}" \
    --key "${ACTUAL_KEY_ID}" 2>/dev/null && echo "  Permissions OK." || echo "  Permissions déjà configurées."
done

echo ""
echo "✓ Garage S3 configuré."
echo "  Endpoint S3:   http://127.0.0.1:${PORT_GARAGE_S3}"
echo "  Buckets:       ${GARAGE_BUCKET_BACKUPS}, ${GARAGE_BUCKET_UPLOADS}"
echo "  Key name:      press-key"
