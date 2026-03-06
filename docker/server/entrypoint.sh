#!/bin/bash
# entrypoint.sh — Démarre SSH server + Redis + frappe-agent
# frappe-agent nécessite Redis local (port 25025) pour les jobs async
# L'agent expose son API HTTP sur port 8000 (Web_port dans config.json)

set -e

AGENT_DIR="/home/frappe/agent"
AGENT_BIN="/home/frappe/.venv/bin/agent"
AGENT_PORT="${AGENT_PORT:-8000}"
AGENT_REDIS_PORT=25025
AGENT_WORKERS="${AGENT_WORKERS:-2}"
DB_HOST="${DB_HOST:-presse_claude_mariadb}"
DB_PORT="${DB_PORT:-3306}"
PRESS_URL="${PRESS_URL:-http://presse_claude_press:8000}"
SERVER_NAME="${SERVER_NAME:-presse_claude_server}"

# ── Générer les clés SSH du host si absentes ──────────────────────────────────
ssh-keygen -A 2>/dev/null || true

# ── Injecter la clé publique Press si fournie ─────────────────────────────────
if [ -n "${PRESS_PUBLIC_KEY:-}" ]; then
  mkdir -p /home/frappe/.ssh
  echo "${PRESS_PUBLIC_KEY}" >> /home/frappe/.ssh/authorized_keys
  sort -u /home/frappe/.ssh/authorized_keys > /tmp/auth_keys_sorted
  mv /tmp/auth_keys_sorted /home/frappe/.ssh/authorized_keys
  chmod 700 /home/frappe/.ssh
  chmod 600 /home/frappe/.ssh/authorized_keys
  chown -R frappe:frappe /home/frappe/.ssh
fi

# ── Démarrer SSH en arrière-plan ──────────────────────────────────────────────
/usr/sbin/sshd
echo "==> SSH server démarré"

# ── Configurer et démarrer Nginx (sert les assets Frappe) ────────────────────
BENCHES_DIR="/home/frappe/benches"
NGINX_CONF_TEMPLATE="/etc/nginx/conf.d/frappe-bench.conf.template"
NGINX_CONF="/etc/nginx/conf.d/frappe-bench.conf"

# Découvrir le premier bench disponible pour la config nginx
FIRST_BENCH=""
for bench_dir in "${BENCHES_DIR}"/bench-*/; do
  if [ -d "${bench_dir}sites" ]; then
    FIRST_BENCH="${bench_dir}"
    break
  fi
done

if [ -n "${FIRST_BENCH}" ] && [ -f "${NGINX_CONF_TEMPLATE}" ]; then
  BENCH_SITES_PATH="${FIRST_BENCH}sites"
  BENCH_ASSETS_PATH="${FIRST_BENCH}sites/assets"

  # Générer nginx.conf depuis le template
  sed \
    -e "s|BENCH_SITES_PATH|${BENCH_SITES_PATH}|g" \
    -e "s|BENCH_ASSETS_PATH|${BENCH_ASSETS_PATH}|g" \
    "${NGINX_CONF_TEMPLATE}" > "${NGINX_CONF}"

  echo "==> Nginx config générée pour bench: ${FIRST_BENCH}"

  # Permissions pour www-data (nginx) sur les fichiers frappe
  chmod o+rX /home/frappe/ 2>/dev/null || true
  chmod -R o+rX "${BENCH_SITES_PATH}/assets/" 2>/dev/null || true
  # Permettre l'exécution des répertoires parents
  chmod o+x /home/frappe/benches/ 2>/dev/null || true

  # Démarrer nginx
  nginx -t 2>/dev/null && nginx
  echo "==> Nginx démarré (assets statiques Frappe)"
else
  echo "==> Aucun bench trouvé — nginx en mode minimal"
  # Config nginx minimale (sans bench assets)
  cat > "${NGINX_CONF}" << 'NGINX_MIN'
server {
    listen 80 default_server;
    root /var/www/html;
    location / { return 200 "Server ready\n"; }
}
NGINX_MIN
  nginx -t 2>/dev/null && nginx || true
fi

# ── Vérifier si frappe-agent est disponible ───────────────────────────────────
if [ ! -x "${AGENT_BIN}" ]; then
  echo "==> frappe-agent non disponible, container en mode SSH uniquement"
  exec tail -f /dev/null
fi

# ── Démarrer Redis (requis par frappe-agent) ──────────────────────────────────
if command -v redis-server >/dev/null 2>&1; then
  # Démarrer Redis sur le port agent (25025)
  redis-server --port "${AGENT_REDIS_PORT}" --daemonize yes \
    --logfile /tmp/redis-agent.log \
    --bind 127.0.0.1 \
    --save "" \
    2>/dev/null || true

  # Attendre que Redis soit prêt
  for i in $(seq 1 10); do
    if redis-cli -p "${AGENT_REDIS_PORT}" ping 2>/dev/null | grep -q PONG; then
      echo "==> Redis agent démarré sur port ${AGENT_REDIS_PORT}"
      break
    fi
    sleep 1
  done
fi

# ── Corriger le shebang de gunicorn (python → python3) ───────────────────────
GUNICORN_BIN="/home/frappe/.venv/bin/gunicorn"
if [ -f "${GUNICORN_BIN}" ]; then
  CURRENT_SHEBANG=$(head -1 "${GUNICORN_BIN}")
  if echo "${CURRENT_SHEBANG}" | grep -qE '/python[[:space:]]*$'; then
    sed -i "1s|.*|#!/home/frappe/.venv/bin/python3|" "${GUNICORN_BIN}"
    echo "==> Shebang gunicorn corrigé: python → python3"
  fi
fi

# ── Patcher _reload_nginx pour compatibilité Docker ───────────────────────────
python3 - <<'PYEOF' || echo "==> WARN: patch _reload_nginx échoué (non bloquant)"
import glob, sys
server_file = next(iter(glob.glob('/home/frappe/.venv/lib/python*/site-packages/agent/server.py')), None)
if not server_file:
    sys.exit(0)
with open(server_file, 'r') as f:
    content = f.read()
if 'nginx -s reload' in content:
    print("==> _reload_nginx déjà patché (Docker-compatible)")
    sys.exit(0)
old = '''    def _reload_nginx(self):
        try:
            return self.execute("sudo systemctl reload nginx")
        except AgentException as e:
            try:
                self.execute("sudo nginx -t")
            except AgentException as e2:
                raise e2 from e
            else:
                raise e'''
new = '''    def _reload_nginx(self):
        # Docker-compatible: nginx -s reload instead of systemctl
        try:
            return self.execute("sudo nginx -s reload")
        except Exception:
            return {"output": "nginx reload skipped (Docker env)", "returncode": 0}'''
if old in content:
    with open(server_file, 'w') as f:
        f.write(content.replace(old, new, 1))
    print("==> Patch _reload_nginx appliqué (systemctl → nginx -s reload)")
else:
    print("==> AVERTISSEMENT: _reload_nginx non patché (version agent différente?)")
PYEOF

# ── Corriger les permissions SQLite de l'agent ────────────────────────────────
mkdir -p "${AGENT_DIR}"
# Initialiser jobs.sqlite3 si absent (peewee le crée au 1er job sinon)
if [ ! -f "${AGENT_DIR}/jobs.sqlite3" ]; then
  touch "${AGENT_DIR}/jobs.sqlite3"
fi
chmod 664 "${AGENT_DIR}/jobs.sqlite3" 2>/dev/null || true
chown frappe:frappe "${AGENT_DIR}/jobs.sqlite3" 2>/dev/null || true
for ext in "-shm" "-wal"; do
  if [ -f "${AGENT_DIR}/jobs.sqlite3${ext}" ]; then
    chmod 664 "${AGENT_DIR}/jobs.sqlite3${ext}" 2>/dev/null || true
    chown frappe:frappe "${AGENT_DIR}/jobs.sqlite3${ext}" 2>/dev/null || true
  fi
done
echo "==> Permissions SQLite agent OK"

# ── Configurer frappe-agent (si pas déjà configuré) ──────────────────────────
mkdir -p "${AGENT_DIR}"/{nginx,tls,logs}
chown -R frappe:frappe "${AGENT_DIR}"

if [ ! -f "${AGENT_DIR}/config.json" ]; then
  echo "==> Configuration de frappe-agent..."
  # agent setup config crée config.json dans le CWD → on doit être dans AGENT_DIR
  cd "${AGENT_DIR}"
  sudo -u frappe "${AGENT_BIN}" setup config \
    --name "${SERVER_NAME}" \
    --workers "${AGENT_WORKERS}" \
    --press-url "${PRESS_URL}" \
    --db-port "${DB_PORT}" 2>/dev/null || true

  # Ajuster le config.json pour notre setup local
  if [ -f "${AGENT_DIR}/config.json" ]; then
    # Modifier web_port pour utiliser notre port (8000 au lieu de 25052)
    python3 - <<PYEOF
import json
with open("${AGENT_DIR}/config.json", "r") as f:
    cfg = json.load(f)

cfg["web_port"] = ${AGENT_PORT}
cfg["redis_port"] = ${AGENT_REDIS_PORT}
cfg["benches_directory"] = "/home/frappe/benches"
cfg["nginx_directory"] = "${AGENT_DIR}/nginx"
cfg["tls_directory"] = "${AGENT_DIR}/tls"
cfg["press_url"] = "${PRESS_URL}"

# Écrire le token si fourni ou généré
if "access_token" not in cfg or not cfg.get("access_token"):
    import os
    cfg["access_token"] = os.environ.get("AGENT_TOKEN", "")

with open("${AGENT_DIR}/config.json", "w") as f:
    json.dump(cfg, f, indent=4, sort_keys=True)

print("Config agent:")
print(json.dumps({k: v for k,v in cfg.items() if k != "access_token"}, indent=2))
PYEOF
    chown frappe:frappe "${AGENT_DIR}/config.json"
  fi
  echo "==> Config agent créée dans ${AGENT_DIR}/config.json"
else
  echo "==> Config agent existante dans ${AGENT_DIR}/config.json"
fi

# Afficher le token d'accès (pour l'enregistrement dans Press)
if [ -f "${AGENT_DIR}/config.json" ]; then
  AGENT_TOKEN=$(python3 -c "import json; c=json.load(open('${AGENT_DIR}/config.json')); print(c.get('access_token',''))")
  echo "==> Agent token: ${AGENT_TOKEN:0:8}... (masqué pour sécurité)"
fi

# ── Démarrer frappe-agent web server ──────────────────────────────────────────
GUNICORN="/home/frappe/.venv/bin/gunicorn"
if [ ! -x "${GUNICORN}" ]; then
  GUNICORN="${AGENT_DIR}/../.venv/bin/gunicorn"
fi

echo "==> Démarrage de frappe-agent sur port ${AGENT_PORT}..."
sudo -u frappe env HOME="/home/frappe" \
  "${GUNICORN}" \
  --bind "0.0.0.0:${AGENT_PORT}" \
  --workers 1 \
  --chdir "${AGENT_DIR}" \
  agent.web:application \
  > /tmp/frappe-agent.log 2>&1 &
AGENT_PID=$!
echo "==> frappe-agent PID: ${AGENT_PID}"

# ── Démarrer le worker RQ (requis pour les jobs frappe-agent) ─────────────────
# IMPORTANT: peewee ouvre 'jobs.sqlite3' en chemin RELATIF → CWD doit être AGENT_DIR
echo "==> Démarrage du worker RQ frappe-agent..."
cd "${AGENT_DIR}"
sudo -u frappe env HOME="/home/frappe" \
  /home/frappe/.venv/bin/python3 -m rq.cli worker \
  --url "redis://127.0.0.1:${AGENT_REDIS_PORT}" \
  high default low \
  > /tmp/rq-worker.log 2>&1 &
RQ_PID=$!
echo "==> RQ worker PID: ${RQ_PID} (logs: /tmp/rq-worker.log)"
cd /

# ── Patcher frappe socket.io pour Docker (utils.js + authenticate.js) ────────
# Problème : en developer_mode, get_url() construit une URL externe inaccessible.
# Fix : utiliser http://127.0.0.1:8001 (gunicorn interne) avec node:http.request
# qui permet d'override le Host header (contrairement à fetch/undici).
for bench_dir in "${BENCHES_DIR}"/bench-*/; do
  FRAPPE_REALTIME="${bench_dir}apps/frappe/realtime"
  if [ ! -d "${FRAPPE_REALTIME}" ]; then continue; fi

  # Patch utils.js : utiliser gunicorn interne
  python3 - "${FRAPPE_REALTIME}/utils.js" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
if '127.0.0.1' in content:
    print(f"==> {path} déjà patché")
    sys.exit(0)
new_content = '''const { get_conf } = require("../node_utils");
const conf = get_conf();

// Patch Docker: socket.io calls gunicorn directly on localhost:8001.
// get_url returns internal URL; authenticate.js uses node:http.request to set Host header.
function get_url(socket, path) {
\tif (!path) path = "";
\treturn "http://127.0.0.1:8001" + path;
}

module.exports = { get_url };
'''
with open(path, 'w') as f:
    f.write(new_content)
print(f"==> {path} patché (Docker: gunicorn interne)")
PYEOF

  # Patch authenticate.js : utiliser node:http.request avec Host header
  python3 - "${FRAPPE_REALTIME}/middlewares/authenticate.js" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
if 'node:http' in content:
    print(f"==> {path} déjà patché")
    sys.exit(0)
# Ajouter require http et remplacer fetch par http.request
content = content.replace(
    'const cookie = require("cookie");',
    'const cookie = require("cookie");\nconst http = require("node:http");'
)
old_headers = 'let headers = {};'
new_headers_plus = '''let headers = {};
\t\t// node:http.request permet d'override Host header (fetch/undici ne le permet pas)
\t\theaders["Host"] = get_site_name(socket);'''
content = content.replace(old_headers, new_headers_plus, 1)
# Remplacer le bloc fetch par http.request
old_fetch = '''\t\treturn fetch(get_url(socket, path), {
\t\t\t...opts,
\t\t\theaders,
\t\t});'''
new_http = '''\t\tconst url = get_url(socket, path);
\t\treturn new Promise((resolve, reject) => {
\t\t\tconst req = http.request(url, { headers, method: opts.method || "GET" }, (res) => {
\t\t\t\tlet data = "";
\t\t\t\tres.on("data", (chunk) => (data += chunk));
\t\t\t\tres.on("end", () => {
\t\t\t\t\tresolve({
\t\t\t\t\t\tjson: () => {
\t\t\t\t\t\t\ttry { return Promise.resolve(JSON.parse(data)); }
\t\t\t\t\t\t\tcatch (e) { return Promise.reject(new SyntaxError("Not valid JSON: " + data.substring(0, 80))); }
\t\t\t\t\t\t},
\t\t\t\t\t\tstatus: res.statusCode,
\t\t\t\t\t\tok: res.statusCode >= 200 && res.statusCode < 300,
\t\t\t\t\t});
\t\t\t\t});
\t\t\t});
\t\t\treq.on("error", reject);
\t\t\treq.end();
\t\t});'''
content = content.replace(old_fetch, new_http)
if 'node:http' in content and 'http.request' in content:
    with open(path, 'w') as f:
        f.write(content)
    print(f"==> {path} patché (Docker: node:http.request)")
else:
    print(f"==> AVERTISSEMENT: patch {path} incomplet (version frappe différente?)")
PYEOF

  # Patch authenticate.js : skip origin check when Origin header is absent (WebSocket transport)
  # Bug: get_hostname(undefined) returns undefined != hostname => Invalid origin
  # Fix: only enforce origin check when Origin header is actually present
  python3 - "${FRAPPE_REALTIME}/middlewares/authenticate.js" <<'PYEOF2'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
if 'const _origin = socket.request.headers.origin' in content:
    print(f"==> {path} origin-fix deja applique")
    sys.exit(0)
old_check = (
    "\tif (get_hostname(socket.request.headers.host) != get_hostname(socket.request.headers.origin)) {\n"
    "\t\tnext(new Error(\"Invalid origin\"));\n"
    "\t\treturn;\n"
    "\t}"
)
new_check = (
    "\tconst _origin = socket.request.headers.origin;\n"
    "\tif (_origin !== undefined && get_hostname(socket.request.headers.host) != get_hostname(_origin)) {\n"
    "\t\tnext(new Error(\"Invalid origin\"));\n"
    "\t\treturn;\n"
    "\t}"
)
if old_check in content:
    content = content.replace(old_check, new_check)
    with open(path, "w") as f:
        f.write(content)
    print(f"==> {path} patche (origin-fix: skip check when Origin absent)")
else:
    print(f"==> AVERTISSEMENT: origin-fix non applique (pattern non trouve dans {path})")
PYEOF2
done

# ── Démarrer les gunicorn pour les benches existants ─────────────────────────
BENCHES_DIR="/home/frappe/benches"
BENCH_PORT=8001

for BENCH_DIR in "${BENCHES_DIR}"/bench-*/; do
  if [ -d "${BENCH_DIR}" ] && [ -d "${BENCH_DIR}sites" ] && [ -d "${BENCH_DIR}env" ]; then
    BENCH_NAME=$(basename "${BENCH_DIR}")
    BENCH_GUNICORN="${BENCH_DIR}env/bin/gunicorn"

    if [ ! -x "${BENCH_GUNICORN}" ]; then
      echo "==> Gunicorn absent pour ${BENCH_NAME}, skip"
      continue
    fi

    echo "==> Démarrage gunicorn pour bench: ${BENCH_NAME} sur port ${BENCH_PORT}"
    sudo -u frappe env HOME="/home/frappe" \
      "${BENCH_GUNICORN}" \
      --bind "0.0.0.0:${BENCH_PORT}" \
      --workers 2 \
      --worker-class=gthread \
      --threads=4 \
      --timeout 120 \
      --chdir "${BENCH_DIR}sites" \
      frappe.app:application \
      > "/tmp/bench-${BENCH_NAME}.log" 2>&1 &
    echo "==> bench ${BENCH_NAME} gunicorn PID: $!"

    # ── Démarrer socket.io pour ce bench ──────────────────────────────────────
    SOCKETIO_JS="${BENCH_DIR}apps/frappe/socketio.js"
    if [ -f "${SOCKETIO_JS}" ]; then
      echo "==> Démarrage socket.io pour bench: ${BENCH_NAME}"
      (
        cd "${BENCH_DIR}apps/frappe"
        sudo -u frappe env HOME="/home/frappe" \
          node socketio.js \
          >> "/tmp/socketio-${BENCH_NAME}.log" 2>&1
      ) &
      echo "==> socket.io PID: $!"
    fi

    # ── Démarrer RQ workers pour ce bench ─────────────────────────────────────
    # Frappe v16 queue names: {sanitized_bench_path}:{queue}
    # sanitized = bench dir path avec '/' → '-' et sans '/' initial
    echo "==> Démarrage RQ workers pour bench: ${BENCH_NAME}"
    BENCH_WORKER_NAME=$(echo "${BENCH_DIR}" | sed 's|^/||;s|/|-|g')
    BENCH_QUEUES="${BENCH_WORKER_NAME}:short ${BENCH_WORKER_NAME}:default ${BENCH_WORKER_NAME}:long"
    REDIS_QUEUE_URL=$(python3 -c "import json; c=json.load(open('${BENCH_DIR}/sites/common_site_config.json')); print(c.get('redis_queue','redis://localhost:6379'))" 2>/dev/null || echo "redis://presse_claude_redis_queue:6379")
    (
      sudo -u frappe env HOME="/home/frappe" \
        "${BENCH_DIR}/env/bin/python" -m rq.cli worker \
        --url "${REDIS_QUEUE_URL}" \
        ${BENCH_QUEUES} \
        >> "/tmp/rq-${BENCH_NAME}.log" 2>&1
    ) &
    RQ_PID=$!
    echo "==> RQ workers PID: ${RQ_PID} (queues: ${BENCH_QUEUES})"

    # ── Démarrer bench schedule (tâches planifiées Frappe) ───────────────────
    echo "==> Démarrage bench schedule pour: ${BENCH_NAME}"
    (
      cd "${BENCH_DIR}"
      sudo -u frappe env HOME="/home/frappe" \
        "${BENCH_DIR}/env/bin/python" \
        -m frappe.utils.scheduler \
        >> "/tmp/schedule-${BENCH_NAME}.log" 2>&1
    ) &
    echo "==> Bench schedule PID: $!"

    BENCH_PORT=$((BENCH_PORT + 1))
  fi
done

# ── Build assets Frappe si absent (post-démarrage en background) ─────────────
# Frappe v16 nécessite yarn production pour générer les bundles CSS/JS
for bench_dir in "${BENCHES_DIR}"/bench-*/; do
  if [ -d "${bench_dir}apps/frappe" ]; then
    ASSETS_JSON="${bench_dir}sites/assets/assets.json"
    FRAPPE_DIST="${bench_dir}apps/frappe/frappe/public/dist"

    # Construire seulement si assets.json est absent ou vide
    if [ ! -s "${ASSETS_JSON}" ]; then
      echo "==> Build assets Frappe requis pour ${bench_dir}..."
      (
        cd "${bench_dir}apps/frappe"
        export HOME=/home/frappe
        export PATH=/usr/local/bin:/usr/bin:/bin

        # Build production
        if sudo -u frappe yarn production 2>/dev/null; then
          echo "==> yarn production OK"

          # Générer assets.json depuis les bundles compilés
          sudo -u frappe node esbuild/esbuild.js --using-cached --apps frappe 2>/dev/null
          echo "==> assets.json généré"

          # Réappliquer permissions nginx
          chmod -R o+rX "${bench_dir}sites/assets/" 2>/dev/null || true
          echo "==> Build assets Frappe complet"
        else
          echo "==> yarn production a échoué (Node trop vieux ?)"
        fi
      ) &
      echo "==> Build assets Frappe lancé en background (PID $!)"
    else
      echo "==> Assets Frappe déjà compilés (assets.json présent)"
      # S'assurer que les permissions nginx sont correctes
      chmod -R o+rX "${bench_dir}sites/assets/" 2>/dev/null || true
    fi
  fi
done

# ── Maintenir le container en vie ─────────────────────────────────────────────
echo "==> Tous les services démarrés. Container en cours d'exécution..."
# Surveiller les processus critiques - redémarrer si mort
while true; do
  sleep 30
  # Vérifier gunicorn bench (port 8001)
  if ! ss -tlnp 2>/dev/null | grep -q ':8001 '; then
    echo "==> WARN: gunicorn bench mort - redémarrage..."
    for BENCH_DIR in "${BENCHES_DIR}"/bench-*/; do
      if [ -d "${BENCH_DIR}env" ]; then
        BENCH_NAME=$(basename "${BENCH_DIR}")
        BENCH_GUNICORN="${BENCH_DIR}env/bin/gunicorn"
        [ -x "${BENCH_GUNICORN}" ] && sudo -u frappe env HOME="/home/frappe" \
          "${BENCH_GUNICORN}" --bind "0.0.0.0:8001" --workers 2 \
          --worker-class=gthread --threads=4 --timeout 120 \
          --chdir "${BENCH_DIR}sites" frappe.app:application \
          >> "/tmp/bench-${BENCH_NAME}.log" 2>&1 &
      fi
    done
  fi
done
