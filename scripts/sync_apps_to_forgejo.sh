#!/bin/bash
# sync_apps_to_forgejo.sh
# Synchronise les apps Frappe officielles depuis GitHub vers Forgejo local
# Usage: ./scripts/sync_apps_to_forgejo.sh [app_name]

set -euo pipefail

FORGEJO_URL="http://localhost:14050"
FORGEJO_USER="gitadmin"
FORGEJO_PASS="presse_admin_2024"
WORK_DIR="/tmp/frappe_apps_sync_$$"

# Apps à synchroniser: (app_name, github_url, branch, forgejo_org)
declare -A APPS_GITHUB=(
    ["frappe"]="https://github.com/frappe/frappe version-16 frappe"
    ["erpnext"]="https://github.com/frappe/erpnext version-16 frappe"
    ["hrms"]="https://github.com/frappe/hrms version-16 frappe"
    ["crm"]="https://github.com/frappe/crm version-1 frappe"
    ["helpdesk"]="https://github.com/frappe/helpdesk main frappe"
    ["lms"]="https://github.com/frappe/lms main frappe"
    ["insights"]="https://github.com/frappe/insights version-3 frappe"
    ["wiki"]="https://github.com/frappe/wiki version-2 frappe"
    ["drive"]="https://github.com/frappe/drive main frappe"
    ["gameplan"]="https://github.com/frappe/gameplan main frappe"
    ["builder"]="https://github.com/frappe/builder main frappe"
    ["print_designer"]="https://github.com/frappe/print_designer version-1 frappe"
    ["payments"]="https://github.com/frappe/payments main frappe"
    ["raven"]="https://github.com/The-Commit-Company/raven main The-Commit-Company"
    ["mail"]="https://github.com/frappe/mail develop frappe"
    # Phase 4 — Apps sectorielles
    ["education"]="https://github.com/frappe/education develop frappe"
    ["hospitality"]="https://github.com/frappe/hospitality develop frappe"
    ["lending"]="https://github.com/frappe/lending develop frappe"
    ["non_profit"]="https://github.com/frappe/non_profit develop frappe"
    ["webshop"]="https://github.com/frappe/webshop develop frappe"
    ["meeting"]="https://github.com/frappe/meeting master frappe"
    ["llm"]="https://github.com/frappe/llm develop frappe"
    # Phase 5 — Community apps
    ["frappe_whatsapp"]="https://github.com/shridarpatil/frappe_whatsapp master frappe"
    # Dépendances
    ["telephony"]="https://github.com/frappe/telephony develop frappe"
)

TARGET="${1:-}"  # Optional: sync only this app

mkdir -p "$WORK_DIR"
trap "rm -rf $WORK_DIR" EXIT

sync_app() {
    local app_name="$1"
    local app_info="${APPS_GITHUB[$app_name]}"
    local github_url=$(echo "$app_info" | cut -d' ' -f1)
    local branch=$(echo "$app_info" | cut -d' ' -f2)
    local org=$(echo "$app_info" | cut -d' ' -f3)
    
    echo "→ Syncing $app_name ($branch) from $github_url..."
    
    local app_dir="$WORK_DIR/$app_name"
    local forgejo_url="http://${FORGEJO_USER}:${FORGEJO_PASS}@localhost:14050/${org}/${app_name}.git"
    
    # Clone sparse from GitHub (only the target branch)
    if git clone --depth=1 --branch "$branch" --single-branch "$github_url" "$app_dir" 2>/dev/null; then
        cd "$app_dir"
        git remote add forgejo "$forgejo_url"
        
        # Push to Forgejo
        if git push forgejo HEAD:refs/heads/"$branch" --force 2>/dev/null; then
            echo "✓ $app_name pushed to Forgejo (branch: $branch)"
        else
            echo "WARN: Push failed for $app_name"
        fi
        cd "$WORK_DIR"
    else
        echo "WARN: Clone failed for $app_name from $github_url"
    fi
}

if [ -n "$TARGET" ]; then
    if [ -z "${APPS_GITHUB[$TARGET]+x}" ]; then
        echo "ERROR: Unknown app '$TARGET'. Available: ${!APPS_GITHUB[@]}"
        exit 1
    fi
    sync_app "$TARGET"
else
    echo "=== Syncing all ${#APPS_GITHUB[@]} apps to Forgejo ==="
    for app_name in "${!APPS_GITHUB[@]}"; do
        sync_app "$app_name"
    done
fi

echo ""
echo "=== Sync complete! Apps available at http://git.press.local ==="
