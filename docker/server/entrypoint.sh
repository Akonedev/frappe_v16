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

# ── Upgrade Flask pour compatibilité Jinja2 3.x ───────────────────────────────
# Flask 1.1.1 (dépendance frappe-agent) est incompatible avec Jinja2 3.x (escape supprimé)
sudo -u frappe /home/frappe/.venv/bin/pip install --quiet "flask>=2.0" 2>/dev/null \
  && echo "==> Flask >= 2.0 installé (compat Jinja2 3.x)" \
  || echo "==> WARN: Flask upgrade échoué (non bloquant)"

# ── Initialiser les tables SQLite de l'agent (peewee) ────────────────────────
# Peewee n'initialise les tables qu'au 1er job si elles n'existent pas;
# RQ worker échouera si les tables manquent → on les crée dès maintenant.
cat > /tmp/agent_sqlite_init.py << 'PYEOF'
import os, sys
os.chdir('/home/frappe/agent')
try:
    from agent.job import agent_database, JobModel, StepModel, PatchLogModel
    agent_database.connect()
    agent_database.create_tables([JobModel, StepModel, PatchLogModel], safe=True)
    agent_database.close()
    print("==> Tables SQLite agent initialisées (JobModel, StepModel, PatchLogModel)")
except Exception as e:
    print(f"==> WARN: init SQLite tables: {e}", file=sys.stderr)
PYEOF
sudo -u frappe env HOME=/home/frappe /home/frappe/.venv/bin/python3 /tmp/agent_sqlite_init.py || true

# ── Patcher agent callbacks.py: envoyer X-Forwarded-For avec le nom du server ─
# Press valide les callbacks par IP (HTTP_X_FORWARDED_FOR), mais :
# 1. L'agent appelle Press directement → header absent → KeyError
# 2. tabServer.ip stocke le nom du container, pas l'IP
# Fix: envoyer X-Forwarded-For: {server_name} (correspond à tabServer.ip)
python3 - << 'PYEOF' || echo "==> WARN: patch agent callbacks.py échoué (non bloquant)"
import glob, sys
cb_file = next(iter(glob.glob('/home/frappe/.venv/lib/python*/site-packages/agent/callbacks.py')), None)
if not cb_file:
    print("==> callbacks.py non trouvé, skip patch")
    sys.exit(0)
with open(cb_file, 'r') as f:
    content = f.read()
if 'X-Forwarded-For' in content:
    print("==> callbacks.py déjà patché (X-Forwarded-For)")
    sys.exit(0)
old = '''def callback(job, connection, result, *args, **kwargs):
    from agent.server import Server

    press_url = Server().press_url
    requests.post(url=f"{press_url}/api/method/press.api.callbacks.callback", data={"job_id": job.id})'''
new = '''def callback(job, connection, result, *args, **kwargs):
    from agent.server import Server

    server = Server()
    press_url = server.press_url
    # Send server name as X-Forwarded-For so Press can identify this server
    # (tabServer.ip stores the container hostname, not an IP)
    server_name = server.config.get("name", "")
    headers = {"X-Forwarded-For": server_name} if server_name else {}
    requests.post(
        url=f"{press_url}/api/method/press.api.callbacks.callback",
        data={"job_id": job.id},
        headers=headers,
    )'''
if old in content:
    with open(cb_file, 'w') as f:
        f.write(content.replace(old, new, 1))
    print("==> Patch callbacks.py appliqué (X-Forwarded-For: server_name)")
else:
    print("==> AVERTISSEMENT: Pattern callbacks.py non trouvé (version agent différente?)")
PYEOF

# ── Patcher agent bench.py: mode no_docker (bare-metal sans Docker Swarm) ────
# L'agent utilise docker_execute() qui appelle Docker Swarm par défaut.
# Avec no_docker:true dans config.json, on exécute les commandes directement via bash.
python3 - << 'PYEOF' || echo "==> WARN: patch bench.py docker_execute échoué (non bloquant)"
import glob, sys
bench_file = next(iter(glob.glob('/home/frappe/.venv/lib/python*/site-packages/agent/bench.py')), None)
if not bench_file:
    print("==> bench.py non trouvé, skip patch")
    sys.exit(0)
with open(bench_file, 'r') as f:
    content = f.read()
if 'no_docker' in content:
    print("==> bench.py déjà patché (no_docker mode)")
    sys.exit(0)
old = """        if subdir:
            workdir = os.path.join(workdir, subdir)

        as_root_flag"""
new = """        if subdir:
            workdir = os.path.join(workdir, subdir)

        # Local bare-metal bench mode (no Docker Swarm)
        if self.bench_config.get("no_docker"):
            full_command = f"bash -c 'cd {workdir} && {command}'"
            return self.execute(
                full_command,
                input=input,
                non_zero_throw=non_zero_throw,
            )

        as_root_flag"""
if old in content:
    with open(bench_file, 'w') as f:
        f.write(content.replace(old, new, 1))
    print("==> Patch bench.py docker_execute appliqué (no_docker mode)")
else:
    print("==> AVERTISSEMENT: Pattern docker_execute non trouvé (version agent différente?)")
PYEOF

# ── Configurer frappe-agent (si pas déjà configuré) ──────────────────────────
mkdir -p "${AGENT_DIR}"/{nginx,tls,logs}
mkdir -p "${AGENT_DIR}"/nginx/{upstreams,sites,conf.d}
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
# Écrit directement les fichiers corrigés (pas de pattern matching fragile).
# Appelé aussi dans la boucle watchdog pour les benches créés après démarrage.

patch_frappe_realtime() {
  local bench_dir="$1"
  local FRAPPE_REALTIME="${bench_dir}apps/frappe/realtime"
  [ -d "${FRAPPE_REALTIME}" ] || return 0

  # utils.js : appel gunicorn interne (Host défini dans authenticate.js)
  cat > "${FRAPPE_REALTIME}/utils.js" << 'UTILS_EOF'
const { get_conf } = require("../node_utils");
const conf = get_conf();

function get_url(socket, path) {
	if (!path) path = "";
	// Docker: appel interne gunicorn — Host header défini dans authenticate.js
	return "http://127.0.0.1:8001" + path;
}

module.exports = { get_url };
UTILS_EOF
  echo "==> ${FRAPPE_REALTIME}/utils.js patché"

  # authenticate.js : origin check robuste + node:http.request avec Host header
  cat > "${FRAPPE_REALTIME}/middlewares/authenticate.js" << 'AUTH_EOF'
const cookie = require("cookie");
const http = require("node:http");
const { get_conf, get_redis_subscriber } = require("../../node_utils");
const { get_url } = require("../utils");
const conf = get_conf();
const redisClient = get_redis_subscriber("redis_queue");

async function getSecretFromRedis() {
	if (!redisClient.isOpen) await redisClient.connect();
	const val = await redisClient.get("socketio_auth_secret");
	return val;
}

function authenticate_with_frappe(socket, next) {
	let namespace = socket.nsp.name;
	namespace = namespace.slice(1, namespace.length);

	if (namespace != get_site_name(socket)) {
		next(new Error("Invalid namespace"));
	}

	// Origin check — skip quand x-frappe-site-name est présent (proxy Traefik/nginx) ou origin absent
	const _origin = socket.request.headers.origin;
	if (_origin && !socket.request.headers["x-frappe-site-name"]) {
		if (get_hostname(socket.request.headers.host) !== get_hostname(_origin)) {
			next(new Error("Invalid origin"));
			return;
		}
	}

	if (!socket.request.headers.cookie && !socket.request.headers.authorization) {
		next(new Error("Missing cookie and authorization header. Either one needed for authentication."));
		return;
	}

	let cookies = cookie.parse(socket.request.headers.cookie || "");
	let authorization_header = socket.request.headers.authorization;

	if (!cookies.sid && !authorization_header) {
		next(new Error("No authentication method used. Use cookie or authorization header."));
		return;
	}
	socket.sid = cookies.sid;
	socket.authorization_header = authorization_header;

	socket.frappe_request = async (path, args = {}, opts = {}) => {
		let query_args = new URLSearchParams(args);
		if (query_args.toString()) {
			path = path + "?" + query_args.toString();
		}

		// node:http.request permet de définir Host header (fetch/undici l'interdit)
		let headers = {
			"Host": get_site_name(socket),
		};
		if (socket.authorization_header) {
			headers["Authorization"] = socket.authorization_header;
		} else if (socket.sid) {
			headers["Cookie"] = "sid=" + socket.sid;
		}
		const secret = await getSecretFromRedis();
		if (secret) {
			headers["X-Frappe-Socket-Secret"] = secret;
		}

		const url = get_url(socket, path);
		return new Promise((resolve, reject) => {
			const req = http.request(url, { headers: headers, method: opts.method || "GET" }, (res) => {
				let data = "";
				res.on("data", (chunk) => (data += chunk));
				res.on("end", () => {
					resolve({
						json: () => {
							try { return Promise.resolve(JSON.parse(data)); }
							catch (e) { return Promise.reject(new SyntaxError("Not valid JSON: " + data.substring(0, 80))); }
						},
						status: res.statusCode,
						ok: res.statusCode >= 200 && res.statusCode < 300,
					});
				});
			});
			req.on("error", reject);
			req.end();
		});
	};

	socket
		.frappe_request("/api/method/frappe.realtime.get_user_info")
		.then((res) => res.json())
		.then(async ({ message }) => {
			if (socket.user !== "Guest" && !message.installed_apps) {
				const retry_res = await socket.frappe_request("/api/method/frappe.realtime.get_user_info");
				const retry_data = await retry_res.json();
				message = retry_data.message;
			}
			socket.user = message.user;
			socket.user_type = message.user_type;
			socket.installed_apps = message.installed_apps || [];
			next();
		})
		.catch((e) => {
			next(new Error("Unauthorized: " + e));
		});
}

function get_site_name(socket) {
	if (socket.site_name) {
		return socket.site_name;
	} else if (socket.request.headers["x-frappe-site-name"]) {
		socket.site_name = get_hostname(socket.request.headers["x-frappe-site-name"]);
	} else if (conf.default_site && ["localhost", "127.0.0.1"].indexOf(get_hostname(socket.request.headers.host)) !== -1) {
		socket.site_name = conf.default_site;
	} else if (socket.request.headers.origin) {
		socket.site_name = get_hostname(socket.request.headers.origin);
	} else {
		socket.site_name = get_hostname(socket.request.headers.host);
	}
	return socket.site_name;
}

function get_hostname(url) {
	if (!url) return undefined;
	if (url.indexOf("://") > -1) {
		url = url.split("/")[2];
	}
	return url.match(/:/g) ? url.slice(0, url.indexOf(":")) : url;
}

module.exports = authenticate_with_frappe;
AUTH_EOF
  echo "==> ${FRAPPE_REALTIME}/middlewares/authenticate.js patché"
}

# Appliquer les patches sur tous les benches existants
for bench_dir in "${BENCHES_DIR}"/bench-*/; do
  patch_frappe_realtime "${bench_dir}"
done

# ── Patcher les bundles Vue SPA (socket.io port/protocol) ───────────────────
# Les apps frappe-ui (CRM, Drive, HRMS, Wiki, Gameplan, LMS, Insights, Helpdesk)
# construisent l'URL socket.io avec port=socketio_port(9000) et protocol=http.
# Derrière Traefik sur :14002 (HTTPS), cela échoue.
# Fix: utiliser window.location.port et window.location.protocol.
patch_vue_spa_socketio() {
  local bench_dir="$1"
  python3 - "$bench_dir" << 'PYEOF'
import re, os, glob, sys

bench_dir = sys.argv[1]
bundle_patterns = [
    f'{bench_dir}/apps/*/*/public/frontend/assets/index-*.js',
    f'{bench_dir}/apps/*/public/raven/assets/index-*.js',
    f'{bench_dir}/apps/*/public/desk/assets/index-*.js',
    f'{bench_dir}/apps/*/*/public/frontend/assets/insights_v2-*.js',
    f'{bench_dir}/apps/*/*/public/frontend/assets/main-*.js',
]
bundle_files = []
for pattern in bundle_patterns:
    bundle_files.extend(glob.glob(pattern))
bundle_files = list(set(bundle_files))

pat_protocol = re.compile(r'\$\{[a-zA-Z_$][a-zA-Z0-9_$]*\?"http":"https"\}://')
pat_port = re.compile(r'window\.location\.port\?`:\$\{(?!window\.location\.port\b)([a-zA-Z_$][a-zA-Z0-9_$]*)\}`')
# Raven frappe-react-sdk PD class: this.port=...c.port?`:${this.socket_port}`:""
pat_raven = re.compile(r'(c\.port\?`:\$\{)(this\.socket_port)(`:"")')

total = 0
for path in bundle_files:
    try:
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
        orig = content
        content = pat_protocol.sub('${window.location.protocol}//', content)
        content = pat_port.sub('window.location.port?`:${window.location.port}`', content)
        content = pat_raven.sub(r'\g<1>window.location.port\g<3>', content)
        if content != orig:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(content)
            total += 1
            print(f'==> Patched {os.path.basename(path)}')
    except Exception as e:
        print(f'==> WARN: {path}: {e}')
if total:
    print(f'==> Vue SPA socket.io: {total} bundle(s) patchés')
PYEOF
}

for bench_dir in "${BENCHES_DIR}"/bench-*/; do
  [ -d "${bench_dir}" ] && patch_vue_spa_socketio "${bench_dir}"
done

patch_desktop_js() {
  local bench_dir="$1"
  python3 - "$bench_dir" << 'PYEOF'
import os, sys
bench_dir = sys.argv[1]
path = os.path.join(bench_dir, 'apps/frappe/frappe/desk/page/desktop/desktop.js')
if not os.path.exists(path):
    sys.exit(0)
with open(path) as f:
    content = f.read()
orig = content
# Fix 1: call setup_edit_button() in make() so the button exists before context menu uses it
content = content.replace(
    '\t\tthis.setup_context_menu();\n\t\tif (this.edit_mode)',
    '\t\tthis.setup_context_menu();\n\t\tthis.setup_edit_button();\n\t\tif (this.edit_mode)',
    )
# Fix 2: null-safe check in onClick in case button is absent (mobile / race)
content = content.replace(
    'me.$desktop_edit_button.hide();',
    'me.$desktop_edit_button && me.$desktop_edit_button.hide();',
    )
# Fix 3: dynamic folder list — items getter (re-evaluated on each menu open)
old_items = (
    '\t\t\t\t\titems: me.folders.map((name) => {\n'
    '\t\t\t\t\t\treturn {\n'
    '\t\t\t\t\t\t\tlabel: name,\n'
    '\t\t\t\t\t\t\tonClick: function () {\n'
    '\t\t\t\t\t\t\t\tadd_icons_to_folder(this.label, [icon_data.label]);\n'
    '\t\t\t\t\t\t\t},\n'
    '\t\t\t\t\t\t};\n'
    '\t\t\t\t\t}),'
)
new_items = (
    '\t\t\t\t\tget items() {\n'
    '\t\t\t\t\t\treturn me.folders.map((name) => {\n'
    '\t\t\t\t\t\t\treturn {\n'
    '\t\t\t\t\t\t\t\tlabel: name,\n'
    '\t\t\t\t\t\t\t\tonClick: function () {\n'
    '\t\t\t\t\t\t\t\t\tadd_icons_to_folder(this.label, [icon_data.label]);\n'
    '\t\t\t\t\t\t\t\t},\n'
    '\t\t\t\t\t\t\t};\n'
    '\t\t\t\t\t\t});\n'
    '\t\t\t\t\t},'
)
content = content.replace(old_items, new_items)
# Fix 4: prepare() rebuilds folders after child_icons are populated (includes App+Folder types with children)
old_prepare_end = (
    '\t\tall_icons.forEach((icon) => {\n'
    '\t\t\tif (icon.parent_icon && icon_map[icon.parent_icon]) {\n'
    '\t\t\t\ticon_map[icon.parent_icon].child_icons.push(icon);\n'
    '\t\t\t}\n\n'
    '\t\t\tif (!icon.parent_icon || !icon_map[icon.parent_icon]) {\n'
    '\t\t\t\tthis.apps_icons.push(icon);\n'
    '\t\t\t}\n'
    '\t\t});\n'
    '\t}'
)
new_prepare_end = (
    '\t\tall_icons.forEach((icon) => {\n'
    '\t\t\tif (icon.parent_icon && icon_map[icon.parent_icon]) {\n'
    '\t\t\t\ticon_map[icon.parent_icon].child_icons.push(icon);\n'
    '\t\t\t}\n\n'
    '\t\t\tif (!icon.parent_icon || !icon_map[icon.parent_icon]) {\n'
    '\t\t\t\tthis.apps_icons.push(icon);\n'
    '\t\t\t}\n'
    '\t\t});\n'
    '\t\t// Rebuild folders to include ALL container icons (Folder type + App types with children)\n'
    '\t\tthis.folders = all_icons\n'
    '\t\t\t.filter((icon) => icon.icon_type === "Folder" || icon.child_icons.length > 0)\n'
    '\t\t\t.map((icon) => icon.label);\n'
    '\t}'
)
content = content.replace(old_prepare_end, new_prepare_end)
if content != orig:
    with open(path, 'w') as f:
        f.write(content)
    print(f'==> Patched desktop.js: 4 fixes (setup_edit_button + null-safe + dynamic getter + all folders)')
PYEOF
}

for bench_dir in "${BENCHES_DIR}"/bench-*/; do
  [ -d "${bench_dir}" ] && patch_desktop_js "${bench_dir}"
done

# ── Démarrer les gunicorn pour les benches existants ─────────────────────────
BENCHES_DIR="/home/frappe/benches"
BENCH_PORT=8001

for BENCH_DIR in "${BENCHES_DIR}"/bench-*/; do
  if [ -d "${BENCH_DIR}" ] && [ -d "${BENCH_DIR}sites" ] && [ -d "${BENCH_DIR}env" ]; then
    BENCH_NAME=$(basename "${BENCH_DIR}")
    BENCH_GUNICORN="${BENCH_DIR}env/bin/gunicorn"

    # Créer config.json si manquant (requis par l'agent pour no_docker mode)
    if [ ! -f "${BENCH_DIR}config.json" ]; then
      echo "==> Création config.json pour ${BENCH_NAME} (no_docker mode)..."
      cat > "${BENCH_DIR}config.json" << 'CFGEOF'
{
    "web_port": 8001,
    "socketio_port": 9001,
    "http_timeout": 120,
    "background_workers": 1,
    "gunicorn_workers": 2,
    "redis_cache": "redis://127.0.0.1:11000",
    "redis_queue": "redis://127.0.0.1:11001",
    "redis_socketio": "redis://127.0.0.1:11002",
    "single_container": false,
    "no_docker": true,
    "docker_image": null
}
CFGEOF
      chown frappe:frappe "${BENCH_DIR}config.json" 2>/dev/null || true
      echo "==> config.json créé pour ${BENCH_NAME}"
    fi

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

  # Vérifier l'agent frappe-agent (port 8000)
  if ! ss -tlnp 2>/dev/null | grep -q ':8000 '; then
    echo "==> WARN: frappe-agent mort - redémarrage..."
    sudo -u frappe env HOME="/home/frappe" \
      /home/frappe/.venv/bin/gunicorn \
      --bind "0.0.0.0:${AGENT_PORT}" --workers 1 \
      --chdir "${AGENT_DIR}" agent.web:application \
      >> /tmp/frappe-agent.log 2>&1 &
  fi

  # Vérifier et redémarrer tous les benches
  CURRENT_PORT=8001
  for BENCH_DIR in "${BENCHES_DIR}"/bench-*/; do
    [ -d "${BENCH_DIR}env" ] || continue
    BENCH_NAME=$(basename "${BENCH_DIR}")
    BENCH_GUNICORN="${BENCH_DIR}env/bin/gunicorn"
    [ -x "${BENCH_GUNICORN}" ] || { CURRENT_PORT=$((CURRENT_PORT+1)); continue; }

    # Créer config.json si un nouveau bench a été créé par l'agent (no_docker mode)
    if [ ! -f "${BENCH_DIR}config.json" ]; then
      cat > "${BENCH_DIR}config.json" << 'CFGEOF'
{
    "web_port": 8001,
    "socketio_port": 9001,
    "http_timeout": 120,
    "background_workers": 1,
    "gunicorn_workers": 2,
    "redis_cache": "redis://127.0.0.1:11000",
    "redis_queue": "redis://127.0.0.1:11001",
    "redis_socketio": "redis://127.0.0.1:11002",
    "single_container": false,
    "no_docker": true,
    "docker_image": null
}
CFGEOF
      chown frappe:frappe "${BENCH_DIR}config.json" 2>/dev/null || true
    fi

    # Redémarrer gunicorn si port non écouté
    if ! ss -tlnp 2>/dev/null | grep -q ":${CURRENT_PORT} "; then
      echo "==> WARN: gunicorn ${BENCH_NAME} mort (port ${CURRENT_PORT}) - redémarrage..."
      sudo -u frappe env HOME="/home/frappe" \
        "${BENCH_GUNICORN}" \
        --bind "0.0.0.0:${CURRENT_PORT}" \
        --workers 2 --worker-class=gthread --threads=4 --timeout 120 \
        --chdir "${BENCH_DIR}sites" frappe.app:application \
        >> "/tmp/bench-${BENCH_NAME}.log" 2>&1 &
    fi

    # Redémarrer socket.io si absent
    SOCKETIO_JS="${BENCH_DIR}apps/frappe/socketio.js"
    if [ -f "${SOCKETIO_JS}" ] && ! pgrep -f "node.*socketio.js" > /dev/null 2>&1; then
      echo "==> WARN: socket.io ${BENCH_NAME} mort - redémarrage..."
      (
        cd "${BENCH_DIR}apps/frappe"
        sudo -u frappe env HOME="/home/frappe" node socketio.js \
          >> "/tmp/socketio-${BENCH_NAME}.log" 2>&1
      ) &
    fi

    # Redémarrer RQ workers si absents
    REDIS_QUEUE_URL=$(python3 -c "import json; c=json.load(open('${BENCH_DIR}/sites/common_site_config.json')); print(c.get('redis_queue','redis://presse_claude_redis_queue:6379'))" 2>/dev/null || echo "redis://presse_claude_redis_queue:6379")
    BENCH_WORKER_NAME=$(echo "${BENCH_DIR}" | sed 's|^/||;s|/|-|g')
    BENCH_QUEUES="${BENCH_WORKER_NAME}:short ${BENCH_WORKER_NAME}:default ${BENCH_WORKER_NAME}:long"
    if ! pgrep -f "rq.cli worker.*${BENCH_WORKER_NAME}" > /dev/null 2>&1; then
      echo "==> WARN: RQ workers ${BENCH_NAME} morts - redémarrage..."
      sudo -u frappe env HOME="/home/frappe" \
        "${BENCH_DIR}/env/bin/python3" -m rq.cli worker \
        --url "${REDIS_QUEUE_URL}" ${BENCH_QUEUES} \
        >> "/tmp/rq-${BENCH_NAME}.log" 2>&1 &
    fi

    CURRENT_PORT=$((CURRENT_PORT + 1))
  done
done
