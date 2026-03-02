#!/usr/bin/env bash
# scripts/backup-mariadb.sh — Backup MariaDB vers Garage S3
# Usage: ./scripts/backup-mariadb.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found"; exit 1; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/mariadb-backups"
CONTAINER="${PREFIX}mariadb"
S3_BUCKET="${S3_BACKUP_BUCKET:-press-backups}"
S3_PREFIX="mariadb-backups"

mkdir -p "${BACKUP_DIR}"

echo "==> Backup MariaDB — ${TIMESTAMP}"

# Lister les bases de données (exclure les bases système)
DATABASES=$(podman exec "${CONTAINER}" \
  mysql -u root -p"${MARIADB_ROOT_PASSWORD}" \
  -e "SHOW DATABASES;" --skip-column-names 2>/dev/null \
  | grep -Ev "^(information_schema|performance_schema|mysql|sys)$")

if [[ -z "${DATABASES}" ]]; then
  echo "WARN: Aucune base de données trouvée"
  exit 0
fi

echo "==> Bases à sauvegarder: $(echo ${DATABASES} | tr '\n' ' ')"

BACKUP_FILE="${BACKUP_DIR}/mariadb_all_${TIMESTAMP}.sql.gz"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: mysqldump all-databases | gzip > ${BACKUP_FILE}"
  echo "DRY-RUN: aws s3 cp ${BACKUP_FILE} s3://${S3_BUCKET}/${S3_PREFIX}/"
  exit 0
fi

# Dump complet compressé
podman exec "${CONTAINER}" \
  mysqldump -u root -p"${MARIADB_ROOT_PASSWORD}" \
  --all-databases --single-transaction --quick --lock-tables=false \
  2>/dev/null | gzip > "${BACKUP_FILE}"

echo "==> Backup créé: ${BACKUP_FILE} ($(du -sh "${BACKUP_FILE}" | cut -f1))"

# Upload vers Garage S3 via awscli (si installé)
if command -v aws &>/dev/null; then
  echo "==> Upload vers S3 (${S3_BUCKET}/${S3_PREFIX}/)..."
  AWS_ACCESS_KEY_ID="${GARAGE_ACCESS_KEY}" \
  AWS_SECRET_ACCESS_KEY="${GARAGE_SECRET_KEY}" \
  aws s3 cp "${BACKUP_FILE}" \
    "s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "${BACKUP_FILE}")" \
    --endpoint-url "http://localhost:${PORT_GARAGE_S3:-14040}" \
    --no-verify-ssl 2>/dev/null \
  && echo "==> Upload OK" \
  || echo "WARN: Upload S3 échoué (awscli non configuré ou S3 indisponible)"
else
  echo "WARN: awscli non installé — backup local uniquement: ${BACKUP_FILE}"
fi

# Nettoyage: garder les 7 derniers backups locaux
find "${BACKUP_DIR}" -name "mariadb_all_*.sql.gz" -mtime +7 -delete 2>/dev/null || true

echo "==> Backup terminé: ${BACKUP_FILE}"
