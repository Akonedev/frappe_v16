#!/bin/bash
# scripts/create-press-client.sh
# Creates a Press user + Team for a client (self-hosted mode, no Stripe)
# Usage: ./scripts/create-press-client.sh EMAIL FIRST_NAME LAST_NAME PASSWORD

set -euo pipefail

EMAIL="${1:-}"
FIRST_NAME="${2:-}"
LAST_NAME="${3:-}"
PASSWORD="${4:-}"

if [ -z "$EMAIL" ] || [ -z "$FIRST_NAME" ] || [ -z "$LAST_NAME" ] || [ -z "$PASSWORD" ]; then
    echo "Usage: $0 <email> <first_name> <last_name> <password>"
    echo "  Ex:  $0 jean@example.com Jean Dupont MonMotDePasse123"
    exit 1
fi

PRESS_CONTAINER="${PRESS_CONTAINER:-presse_claude_press}"
BENCH_DIR="/home/frappe/frappe-bench"
SITE="press.local"

echo "==> Creating Press client: ${EMAIL} (${FIRST_NAME} ${LAST_NAME})"

# Write Python script to container
podman exec "$PRESS_CONTAINER" bash -c "cat > /tmp/create_client_tmp.py" << PYEOF
import frappe
from frappe.utils.password import update_password

EMAIL = '${EMAIL}'
FIRST_NAME = '${FIRST_NAME}'
LAST_NAME = '${LAST_NAME}'
PASSWORD = '${PASSWORD}'

if not frappe.db.exists('User', EMAIL):
    user = frappe.get_doc({
        'doctype': 'User',
        'email': EMAIL,
        'first_name': FIRST_NAME,
        'last_name': LAST_NAME,
        'send_welcome_email': 0,
        'enabled': 1,
        'roles': [
            {'role': 'Press Admin'},
            {'role': 'Press Member'},
        ],
    })
    user.insert(ignore_permissions=True)
    update_password(EMAIL, PASSWORD)
    frappe.db.commit()
    print('User created: ' + EMAIL)
else:
    print('User exists: ' + EMAIL)

if not frappe.db.exists('Team', EMAIL):
    now = frappe.utils.now()
    frappe.db.sql(
        'INSERT INTO \`tabTeam\` (name, creation, modified, modified_by, owner, docstatus, team_title, user, enabled, billing_name, country, currency, payment_mode) VALUES (%s, %s, %s, %s, %s, 0, %s, %s, 1, %s, %s, %s, %s)',
        (EMAIL, now, now, 'Administrator', 'Administrator',
         FIRST_NAME + ' ' + LAST_NAME, EMAIL,
         FIRST_NAME + ' ' + LAST_NAME, 'France', 'USD', '')
    )
    member_id = frappe.generate_hash(length=10)
    frappe.db.sql(
        'INSERT INTO \`tabTeam Member\` (name, creation, modified, modified_by, owner, parent, parentfield, parenttype, user) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)',
        (member_id, now, now, 'Administrator', 'Administrator', EMAIL, 'team_members', 'Team', EMAIL)
    )
    frappe.db.commit()
    print('Team created: ' + EMAIL)
else:
    print('Team exists: ' + EMAIL)

print('Ready: ' + EMAIL + ' can login at http://press.local:14010')
PYEOF

podman exec "$PRESS_CONTAINER" bash -c "cd ${BENCH_DIR} && bench --site ${SITE} execute \"exec(open('/tmp/create_client_tmp.py').read())\" && rm -f /tmp/create_client_tmp.py"

echo "==> Done!"
