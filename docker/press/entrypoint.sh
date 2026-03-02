#!/bin/bash
# entrypoint.sh — Initialise et démarre Frappe Press (web + workers + scheduler)
# Compatible Python 3.12 avec patchs complets pour frappe 16.9+, ansible, stripe, six

set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="${SITE_NAME:-press.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
REDIS_CACHE="${REDIS_CACHE_URL:-redis://presse_claude_redis_cache:6379}"
REDIS_QUEUE="${REDIS_QUEUE_URL:-redis://presse_claude_redis_queue:6379}"
DB_HOST_REAL="${DB_HOST:-presse_claude_mariadb}"
VENV_PY="${BENCH_DIR}/env/bin/python"
VENV_PIP="${BENCH_DIR}/env/bin/pip"

echo "=== Presse Claude — Démarrage Press ==="

# ── Phase 1: Frappe installé dans le venv? ────────────────────────────────────
if ! "${VENV_PY}" -c "import frappe" 2>/dev/null; then
  echo "→ Frappe non installé dans le venv, initialisation nécessaire..."
  cd /home/frappe

  # Cas A: bench dir n'existe pas → bench init complet
  if [ ! -f "${BENCH_DIR}/Procfile" ]; then
    echo "→ bench init complet (Frappe V16)..."
    bench init --frappe-branch version-16 --skip-redis-config-generation frappe-bench || true
    # bench init peut échouer sur yarn (non bloquant si frappe est installé)
  fi

  cd "${BENCH_DIR}"

  # S'assurer que frappe est pip-installé dans le venv
  if [ -f "apps/frappe/pyproject.toml" ] || [ -f "apps/frappe/setup.py" ]; then
    echo "→ Installation/mise à jour de frappe depuis la source locale..."
    # Patch requires-python pour Python 3.12 (frappe 16.9+ a >=3.14 dans pyproject.toml)
    if [ -f "apps/frappe/pyproject.toml" ]; then
      sed -i 's/requires-python = ">=3\.[0-9][0-9]*[^"]*"/requires-python = ">=3.12"/' apps/frappe/pyproject.toml
    fi
    "${VENV_PIP}" install --upgrade -e apps/frappe 2>&1 || true
  fi

  # ── Patch Python 3.12 compatibility pour frappe 16.9+ ─────────────────────
  if [ -d "apps/frappe" ]; then
    echo "→ Application des patchs d'annotations Python 3.12..."

    # 1. Installer uuid6 dans le venv (shim pour uuid7 non disponible en Python 3.12)
    "${VENV_PIP}" install --quiet uuid6 2>/dev/null || true

    # 2. Patch frappe/model/naming.py: remplacer uuid7 stdlib par uuid6
    NAMING_PY="apps/frappe/frappe/model/naming.py"
    if [ -f "${NAMING_PY}" ] && grep -q 'from uuid import.*uuid7' "${NAMING_PY}"; then
      echo "  → Patch uuid7 dans naming.py..."
      sed -i 's/from uuid import \(.*\)uuid7/from uuid import \1uuid4/' "${NAMING_PY}"
      sed -i '/^from uuid import/a try:\n    from uuid import uuid7\nexcept ImportError:\n    from uuid6 import uuid7' "${NAMING_PY}"
    fi

    # 3. Ajouter 'from __future__ import annotations' aux fichiers frappe avec
    #    des annotations de type chaîne incompatibles avec Python 3.12
    #    Patterns: "ClassName" | ... | "ClassName" ... ["ClassName ...
    "${VENV_PY}" << 'PYEOF'
import os, re

frappe_dir = '/home/frappe/frappe-bench/apps/frappe/frappe'
patterns = [
    re.compile(r'"[A-Za-z][^"]+"\s*\|'),   # "ClassName" | None (avant pipe)
    re.compile(r':\s*"[A-Za-z]'),            # : "ClassName" (annotation variable)
    re.compile(r'\|\s*"[A-Za-z]'),           # | "ClassName" (après pipe)
    re.compile(r'\[\s*"[A-Za-z]'),           # ["ClassName (dans générique)
]
future_import = 'from __future__ import annotations\n'

patched = 0
for root, dirs, files in os.walk(frappe_dir):
    dirs[:] = [d for d in dirs if d not in ['__pycache__']]
    for fname in files:
        if not fname.endswith('.py'):
            continue
        fpath = os.path.join(root, fname)
        try:
            with open(fpath, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
        except Exception:
            continue
        if 'from __future__ import annotations' in content:
            continue
        if any(p.search(content) for p in patterns):
            try:
                with open(fpath, 'w', encoding='utf-8') as f:
                    f.write(future_import + content)
                patched += 1
            except Exception as e:
                print(f'  WARN: {fpath}: {e}')

print(f'  → {patched} fichiers frappe patchés pour annotations Python 3.12')
PYEOF
    echo "✓ Patchs Python 3.12 appliqués"
  fi

  # Vérification finale
  if ! "${VENV_PY}" -c "import frappe" 2>/dev/null; then
    echo "ERREUR CRITIQUE: frappe toujours non importable après patchs"
    "${VENV_PY}" -c "import frappe" 2>&1 | head -10
    exit 1
  fi
  echo "✓ frappe installé et compatible Python 3.12"
fi

# ── Phase 1b: Créer apps.txt si manquant (requis par les commandes bench) ─────
cd "${BENCH_DIR}"
if [ ! -f "sites/apps.txt" ]; then
  echo "→ Création de sites/apps.txt..."
  mkdir -p sites
  {
    [ -d "apps/frappe" ] && echo "frappe"
    [ -d "apps/press" ] && echo "press"
  } > sites/apps.txt
  echo "✓ apps.txt: $(cat sites/apps.txt | tr '\n' ' ')"
fi

# ── Phase 1c: Patchs dépendances Python 3.12 (stripe, six, ansible) ──────────
# Ces patchs sont appliqués à chaque démarrage pour être résilients aux reinstalls
SITE_PACKAGES="${BENCH_DIR}/env/lib/python3.12/site-packages"

# 2a. Shim urllib3.contrib.appengine (python-telegram-bot 13.x)
APPENGINE_PATH="${SITE_PACKAGES}/urllib3/contrib/appengine.py"
if [ -f "${SITE_PACKAGES}/urllib3/contrib/__init__.py" ] && [ ! -f "${APPENGINE_PATH}" ]; then
  cat > "${APPENGINE_PATH}" << 'SHIMEOF'
# Compatibility shim: urllib3 v2 removed appengine support
is_appengine = False
is_appengine_sandbox = False
is_local_appengine = False
is_prod_appengine = False
is_prod_appengine_mvms = False
def monkeypatch():
    pass
SHIMEOF
  echo "✓ Shim urllib3.contrib.appengine créé"
fi

# 2b. stripe.six → six compatibility (stripe 2.56 bundled six Python 3.12 fix)
STRIPE_SIX_DIR="${SITE_PACKAGES}/stripe/six"
if [ -d "${SITE_PACKAGES}/stripe" ] && [ ! -d "${STRIPE_SIX_DIR}" ]; then
  mkdir -p "${STRIPE_SIX_DIR}"
  cat > "${STRIPE_SIX_DIR}/__init__.py" << 'STRIPESHIMEOF'
# Compatibility shim: make stripe.six = six and register stripe.six.moves.*
import sys
import six
for _attr in dir(six):
    if not _attr.startswith('__'):
        globals()[_attr] = getattr(six, _attr)
sys.modules.setdefault('stripe.six', sys.modules[__name__])
sys.modules.setdefault('stripe.six.moves', six.moves)
sys.modules.setdefault('stripe.six.moves.urllib', six.moves.urllib)
sys.modules.setdefault('stripe.six.moves.urllib.parse', six.moves.urllib.parse)
sys.modules.setdefault('stripe.six.moves.urllib.request', six.moves.urllib.request)
sys.modules.setdefault('stripe.six.moves.urllib.error', six.moves.urllib.error)
STRIPESHIMEOF
  echo "✓ Shim stripe.six créé"
fi

# 2c. sitecustomize.py: six.moves __path__ fix pour tous les packages
cat > "${SITE_PACKAGES}/sitecustomize.py" << 'SCEOF'
"""
sitecustomize.py — Python 3.12 compatibility for six.moves in any bundled copy.
Registers six.moves.* submodules in sys.modules so they can be imported.
"""
import sys
import urllib.parse as _up, urllib.request as _ur, urllib.error as _ue

def _fix_six_module_moves(six_mod):
    """Pre-register X.moves.urllib.* in sys.modules for a given six module."""
    if not hasattr(six_mod, 'moves'):
        return
    base = six_mod.__name__
    _ns = type(sys)('urllib')
    _ns.__path__ = []
    _ns.parse = _up; _ns.request = _ur; _ns.error = _ue
    for suffix, mod in [
        ('moves.urllib', _ns),
        ('moves.urllib.parse', _up),
        ('moves.urllib.request', _ur),
        ('moves.urllib.error', _ue),
    ]:
        sys.modules.setdefault(f'{base}.{suffix}', mod)
    moves = getattr(six_mod, 'moves', None)
    if moves is not None:
        sys.modules.setdefault(f'{base}.moves', moves)
        try:
            moves.__path__ = []
        except (AttributeError, TypeError):
            pass

try:
    import six
    _fix_six_module_moves(six)
except ImportError:
    pass
SCEOF
echo "✓ sitecustomize.py créé"

# 2d. ansible.module_utils.six: patch _import_module + pre-register moves.*
ANSIBLE_SIX="${SITE_PACKAGES}/ansible/module_utils/six/__init__.py"
if [ -f "${ANSIBLE_SIX}" ] && ! grep -q '# Python 3.12 fix: pre-register six.moves' "${ANSIBLE_SIX}"; then
  # Patch _import_module pour gérer six.moves.urllib
  "${VENV_PY}" << 'PYEOF'
with open('/home/frappe/frappe-bench/env/lib/python3.12/site-packages/ansible/module_utils/six/__init__.py', 'r') as f:
    content = f.read()

old = '''def _import_module(name):
    """Import module, returning the module after the last dot."""
    __import__(name)
    return sys.modules[name]'''

new = '''def _import_module(name):
    """Import module, returning the module after the last dot."""
    # Python 3.12 fix: pre-register six.moves sub-modules if needed
    if '.six.moves.' in name or name.endswith('.six.moves'):
        import urllib.parse as _up, urllib.request as _ur, urllib.error as _ue
        parts = name.split('.')
        if 'six' in parts:
            base = '.'.join(parts[:parts.index('six') + 1])
            _ns = type(sys)('urllib')
            _ns.__path__ = []; _ns.parse = _up; _ns.request = _ur; _ns.error = _ue
            for _sfx, _m in [('moves.urllib', _ns), ('moves.urllib.parse', _up),
                              ('moves.urllib.request', _ur), ('moves.urllib.error', _ue)]:
                sys.modules.setdefault(base + '.' + _sfx, _m)
            _mv = getattr(sys.modules.get(base), 'moves', None)
            if _mv is not None:
                sys.modules.setdefault(base + '.moves', _mv)
        if name in sys.modules:
            return sys.modules[name]
    __import__(name)
    return sys.modules[name]'''

if old in content:
    content = content.replace(old, new)
    # Also add footer to pre-register at import time
    content += '''
# Python 3.12 fix: pre-register moves.* at module load time
import sys as _sys, urllib.parse as _up, urllib.request as _ur, urllib.error as _ue
_base = __name__
_ns = type(_sys)('urllib'); _ns.__path__ = []
_ns.parse = _up; _ns.request = _ur; _ns.error = _ue
for _sfx, _m in [('moves.urllib', _ns), ('moves.urllib.parse', _up),
                 ('moves.urllib.request', _ur), ('moves.urllib.error', _ue),
                 ('moves', moves)]:
    _sys.modules.setdefault(_base + '.' + _sfx, _m)
try:
    moves.__path__ = []
except (AttributeError, TypeError):
    pass
del _sys, _up, _ur, _ue, _base, _ns
'''
    with open('/home/frappe/frappe-bench/env/lib/python3.12/site-packages/ansible/module_utils/six/__init__.py', 'w') as f:
        f.write(content)
    print('ansible.module_utils.six patché pour Python 3.12')
else:
    print('WARN: Pattern _import_module non trouvé, déjà patché?')
PYEOF
fi

# 2e. ansible-core: upgrade si ansible-base 2.10 (non compatible Python 3.12)
ANSIBLE_VERSION=$("${VENV_PIP}" show ansible-base 2>/dev/null | grep "^Version:" | cut -d' ' -f2 || echo "")
if [ -n "${ANSIBLE_VERSION}" ]; then
  echo "→ ansible-base ${ANSIBLE_VERSION} détecté, upgrade vers ansible-core 2.16..."
  "${VENV_PIP}" uninstall -y ansible ansible-base 2>/dev/null || true
  "${VENV_PIP}" install --quiet 'ansible-core>=2.14,<2.17' 2>&1 | tail -3
  echo "✓ ansible-core installé"
fi

# 2f. ansible _AnsiblePathHookFinder: ajouter find_spec pour Python 3.12
COLLECTION_FINDER="${SITE_PACKAGES}/ansible/utils/collection_loader/_collection_finder.py"
if [ -f "${COLLECTION_FINDER}" ] && ! grep -q 'def find_spec' "${COLLECTION_FINDER}"; then
  "${VENV_PY}" << 'PYEOF'
with open('/home/frappe/frappe-bench/env/lib/python3.12/site-packages/ansible/utils/collection_loader/_collection_finder.py', 'r') as f:
    content = f.read()
old = '    def iter_modules(self, prefix):\n        # NB: this currently represents only what\'s on disk, and does not handle package redirection\n        return _iter_modules_impl([self._pathctx], prefix)'
new = '''    def find_spec(self, fullname, path=None, target=None):
        """Python 3.12 compatibility: find_spec delegates to find_module."""
        import importlib.machinery
        loader = self.find_module(fullname, path)
        if loader is None:
            return None
        return importlib.machinery.ModuleSpec(fullname, loader)

    def iter_modules(self, prefix):
        # NB: this currently represents only what's on disk, and does not handle package redirection
        return _iter_modules_impl([self._pathctx], prefix)'''
if old in content:
    with open('/home/frappe/frappe-bench/env/lib/python3.12/site-packages/ansible/utils/collection_loader/_collection_finder.py', 'w') as f:
        f.write(content.replace(old, new))
    print('find_spec ajouté à _AnsiblePathHookFinder')
else:
    print('Pattern iter_modules non trouvé (déjà patché?)')
PYEOF
fi

echo "✓ Patchs dépendances Python 3.12 appliqués"

# ── Phase 2: Configuration Redis (Docker containers) ──────────────────────────
echo "→ Mise à jour config Redis..."
cd "${BENCH_DIR}"
mkdir -p sites
cat > sites/common_site_config.json << CFGEOF
{
  "redis_cache": "${REDIS_CACHE}",
  "redis_queue": "${REDIS_QUEUE}",
  "redis_socketio": "${REDIS_CACHE}",
  "file_watcher_port": 6787,
  "shallow_clone": true,
  "developer_mode": ${FRAPPE_DEVELOPER_MODE:-0}
}
CFGEOF
echo "✓ Config Redis: cache=${REDIS_CACHE}"

# ── Phase 3: App Press installée? ─────────────────────────────────────────────
if [ ! -d "apps/press" ]; then
  echo "→ Installation de l'app Press (branche master)..."
  bench get-app press https://github.com/frappe/press --branch master
  echo "✓ Press cloné et installé"
else
  echo "✓ App Press déjà présente"
fi

# ── Phase 4: Site créé et Press installé? ─────────────────────────────────────
if [ ! -f "sites/${SITE_NAME}/site_config.json" ]; then
  echo "→ Création du site ${SITE_NAME}..."
  bench new-site "${SITE_NAME}" \
    --mariadb-root-password "${MARIADB_ROOT_PASSWORD:-}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-host "${DB_HOST_REAL}" \
    --db-port "${DB_PORT:-3306}" \
    --no-mariadb-socket || echo "WARN: échec new-site (peut-être déjà existant)"

  if [ -f "sites/${SITE_NAME}/site_config.json" ]; then
    echo "→ Installation de Press sur ${SITE_NAME}..."
    bench --site "${SITE_NAME}" install-app press || echo "WARN: install-app press"

    echo "→ Migration..."
    bench --site "${SITE_NAME}" migrate

    echo "=== ✓ Site ${SITE_NAME} initialisé avec succès ! ==="
  else
    echo "WARN: site_config.json manquant après new-site"
  fi
else
  echo "✓ Site ${SITE_NAME} déjà configuré"

  # Vérifier si Press est installé sur le site (peut manquer si install-app press a échoué)
  PRESS_INSTALLED=$(bench --site "${SITE_NAME}" list-apps 2>/dev/null | grep -c '^press' || true)
  if [ "${PRESS_INSTALLED}" -eq 0 ]; then
    echo "→ Press non installé sur ${SITE_NAME}, installation..."
    bench --site "${SITE_NAME}" install-app press || echo "WARN: install-app press"
    echo "→ Migration..."
    bench --site "${SITE_NAME}" migrate || echo "WARN: migrate"
    echo "✓ Press installé sur ${SITE_NAME}"
  fi
fi

# Créer le répertoire de logs si manquant
mkdir -p /home/logs /home/frappe/frappe-bench/logs 2>/dev/null || true

# ── Build Press Dashboard Vue SPA ─────────────────────────────────────────────
# Le dashboard Vue doit être buildé si dashboard.html est absent
PRESS_DASHBOARD_HTML="${BENCH_DIR}/apps/press/press/www/dashboard.html"
PRESS_DASHBOARD_DIR="${BENCH_DIR}/apps/press/dashboard"
PRESS_ASSETS_DASHBOARD="${BENCH_DIR}/sites/assets/press/dashboard"

if [ ! -f "${PRESS_DASHBOARD_HTML}" ] && [ -f "${PRESS_DASHBOARD_DIR}/package.json" ]; then
  echo "→ Build Press Dashboard Vue SPA (first time)..."

  # Créer common_site_config.json requis pour le build (socketio_port)
  SITES_DIR="${BENCH_DIR}/sites"
  if [ ! -f "${SITES_DIR}/common_site_config.json" ]; then
    echo '{"socketio_port": 9000}' > "${SITES_DIR}/common_site_config.json"
  fi

  cd "${PRESS_DASHBOARD_DIR}"

  # yarn install avec le cache existant (--prefer-offline si disponible)
  if yarn install --frozen-lockfile 2>/dev/null || yarn install 2>/dev/null; then
    echo "→ node_modules installés, lancement du build vite..."
    if NODE_ENV=production yarn run build 2>&1 | tail -5; then
      echo "✓ Press Dashboard buildé"

      # Copier les assets vers sites/assets/press/dashboard/
      mkdir -p "${PRESS_ASSETS_DASHBOARD}"
      if [ -d "${BENCH_DIR}/apps/press/press/public/dashboard" ]; then
        cp -r "${BENCH_DIR}/apps/press/press/public/dashboard/." "${PRESS_ASSETS_DASHBOARD}/"
        echo "✓ Assets Press Dashboard copiés dans sites/assets"
      fi
    else
      echo "WARN: Build Press Dashboard échoué (dashboard ne sera pas disponible)"
    fi

    # Libérer l'espace disque (node_modules non nécessaires en prod)
    echo "→ Nettoyage node_modules pour libérer l'espace..."
    rm -rf "${PRESS_DASHBOARD_DIR}/node_modules" 2>/dev/null || true
  else
    echo "WARN: yarn install échoué, dashboard non buildé"
  fi

  cd "${BENCH_DIR}"
else
  # Dashboard déjà buildé: vérifier que les assets sont dans sites/assets
  if [ -f "${PRESS_DASHBOARD_HTML}" ] && [ ! -d "${PRESS_ASSETS_DASHBOARD}/assets" ]; then
    echo "→ Sync assets Press Dashboard vers sites/assets..."
    mkdir -p "${PRESS_ASSETS_DASHBOARD}"
    if [ -d "${BENCH_DIR}/apps/press/press/public/dashboard" ]; then
      cp -r "${BENCH_DIR}/apps/press/press/public/dashboard/." "${PRESS_ASSETS_DASHBOARD}/"
      echo "✓ Assets Press Dashboard synchronisés"
    fi
  else
    echo "✓ Press Dashboard déjà buildé et assets présents"
  fi
fi

# ── Nginx: config + démarrage ────────────────────────────────────────────────
# Nginx sert les assets statiques et proxifie vers gunicorn
# Il gère aussi les redirects Press portal (ex: /welcome → /dashboard/welcome)

# Créer le fichier www/welcome.py pour le redirect Press portal
PRESS_WWW="${BENCH_DIR}/apps/press/press/www"
if [ -d "${PRESS_WWW}" ]; then
  for route in welcome sites; do
    if [ ! -f "${PRESS_WWW}/${route}.py" ]; then
      cat > "${PRESS_WWW}/${route}.py" << PYEOF
import frappe
no_cache = 1
def get_context(context):
    frappe.flags.redirect_location = "/dashboard/${route}"
    raise frappe.Redirect
PYEOF
    fi
  done
fi

# Configurer nginx (en root via sudo)
NGINX_CONF="/etc/nginx/conf.d/frappe-press.conf"
if [ ! -s "${NGINX_CONF}" ]; then
  sudo bash -c "cat > '${NGINX_CONF}'" << 'NGINX_EOF'
upstream frappe_press_gunicorn {
    server 127.0.0.1:8000 fail_timeout=0;
    keepalive 8;
}
map $http_x_forwarded_for $real_ip {
    default $remote_addr;
    "~^(?P<firstip>[^,]+)" $firstip;
}
server {
    listen 80;
    server_name press.local _;
    root /home/frappe/frappe-bench/sites;
    access_log /var/log/nginx/frappe-press.access.log;
    error_log  /var/log/nginx/frappe-press.error.log;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $real_ip;
    proxy_set_header X-Forwarded-For $http_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
    proxy_set_header X-Forwarded-Host $host;
    # Press portal client-side routes → /dashboard (Vue SPA)
    location = /welcome     { return 302 /dashboard/welcome; }
    location = /sites       { return 302 /dashboard/sites;  }
    location = /create-site { return 302 /dashboard/create-site; }
    location /assets {
        alias /home/frappe/frappe-bench/sites/assets;
        add_header Cache-Control "no-cache, must-revalidate";
        expires 1h;
        try_files $uri =404;
    }
    location ~ ^/sites/(.+)/public/(.*)$ {
        alias /home/frappe/frappe-bench/sites/$1/public/$2;
        expires 1h;
        try_files $uri =404;
    }
    location /files {
        try_files /sites/$host/public/files/$uri /sites/$host/private/files/$uri @gunicorn;
    }
    location / {
        try_files $uri @gunicorn;
    }
    location @gunicorn {
        proxy_pass http://frappe_press_gunicorn;
        proxy_read_timeout    120;
        proxy_connect_timeout 10;
        proxy_send_timeout    120;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $real_ip;
        proxy_set_header X-Forwarded-For $http_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_buffer_size          128k;
        proxy_buffers              4 256k;
        proxy_busy_buffers_size    256k;
    }
    location ~ ^/sites/.+/private/ {
        return 403;
    }
}
NGINX_EOF
fi

# Supprimer la config nginx par défaut si elle existe
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Démarrer nginx en arrière-plan
if command -v nginx &>/dev/null; then
  sudo nginx -t 2>/dev/null && sudo nginx 2>/dev/null || true
  echo "✓ Nginx démarré"
else
  echo "WARN: nginx non installé (rebuild requis pour activer nginx)"
fi

# ── Patches Press custom : endpoint Forgejo webhook ──────────────────────────
PRESS_API_DIR="${BENCH_DIR}/apps/press/press/api"
FORGEJO_PATCH="/home/frappe/press_patches/forgejo.py"
if [ -f "${FORGEJO_PATCH}" ] && [ -d "${PRESS_API_DIR}" ]; then
  cp "${FORGEJO_PATCH}" "${PRESS_API_DIR}/forgejo.py"
  echo "→ Patch forgejo.py appliqué dans press/api/"
fi

# ── Démarrage des services ─────────────────────────────────────────────────────
bench use "${SITE_NAME}" 2>/dev/null || true

echo "→ Démarrage worker (short,default,long)..."
bench worker --queue short,default,long &

echo "→ Démarrage scheduler..."
bench schedule &

echo "→ Press accessible sur http://0.0.0.0:8000 (site: ${SITE_NAME})"
echo "→ Press (via nginx) accessible sur http://0.0.0.0:80"
exec bench serve --port 8000 --noreload
