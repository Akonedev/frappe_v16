# Makefile — Presse Claude: commandes rapides (Podman)
.PHONY: install start stop restart logs status clean \
        ps info network test \
        press-shell server-shell setup-press register-server dns dns-remove webhooks mkcert build \
        quadlets-install quadlets-check \
        quadlets-start-core quadlets-start-small quadlets-start-medium quadlets-start-large quadlets-start-gpu \
        quadlets-stop-all quadlets-stop-ai quadlets-stop-monitoring quadlets-stop-devtools quadlets-stop-press quadlets-stop-core \
        quadlets-status quadlets-logs quadlets-enable quadlets-enable-linger \
        build-press build-server \
        backup backup-dry \
        quadlets-install-small quadlets-install-medium quadlets-install-large quadlets-install-gpu \
        quadlets-enable-medium quadlets-enable-large quadlets-enable-gpu \
        quadlets-logs-core quadlets-logs-press

COMPOSE_FILE=podman-compose.yml
ENV=--env-file .env
PC=podman-compose -f $(COMPOSE_FILE) $(ENV)
PREFIX=$(shell grep '^PREFIX=' .env | cut -d= -f2)

install:
	./scripts/install.sh

build:
	$(PC) build

start:
	$(PC) up -d

stop:
	$(PC) stop

restart:
	$(PC) restart

logs:
	$(PC) logs -f

status:
	@podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep presse_claude || echo "(aucun container presse_claude actif)"

# Vue projet enrichie — UNIQUEMENT les containers presse_claude_*
ps:
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║              PRESSE CLAUDE — Containers actifs              ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
	@echo ""
	@podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
	  --filter "name=^presse_claude_" | sort
	@echo ""
	@printf "  Réseau : presse_claude_network (subnet 172.30.0.0/16, DNS activé)\n"
	@printf "  Containers sur le réseau : $(shell podman ps --filter 'name=^presse_claude_' -q | wc -l)/14\n"
	@echo ""

# Informations complètes du projet
info:
	@echo ""
	@echo "══ Presse Claude — Vue projet ══════════════════════════════════"
	@echo ""
	@echo "── Containers ($(shell podman ps --filter 'name=^presse_claude_' -q | wc -l)/14 actifs) ──"
	@podman ps --filter "name=^presse_claude_" \
	  --format "  {{.Names}}\t{{.Status}}" | column -t
	@echo ""
	@echo "── Réseau isolé : presse_claude_network (172.30.0.0/16) ──"
	@podman ps --filter "name=^presse_claude_" -q | while read id; do \
	  name=$$(podman inspect "$$id" --format "{{.Name}}" 2>/dev/null); \
	  ip=$$(podman inspect "$$id" --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" 2>/dev/null); \
	  printf "  %-35s %s\n" "$$name" "$$ip"; \
	done | sort
	@echo ""
	@echo "── Volumes projet (presse_claude_*) ──"
	@podman volume ls --filter "name=^presse_claude_" --format "  {{.Name}}" | sort
	@echo ""
	@echo "── Services systemd actifs (presse-claude-*.service) ──"
	@systemctl --user list-units 'presse-claude-*.service' --state=active --no-legend 2>/dev/null \
	  | awk '{print "  " $$1}' | grep -v "volume\|network" | sort || echo "  (aucun service actif)"
	@echo ""

# Vérifier l'isolation réseau
network:
	@echo "── Réseau presse_claude_network ──"
	@podman network inspect presse_claude_network 2>/dev/null \
	  | python3 -c "import sys,json; \
	    data=json.load(sys.stdin); \
	    d=data[0] if data else {}; \
	    sub=d.get('subnets',[{}])[0].get('subnet','N/A'); \
	    print(f'  Subnet : {sub}'); \
	    print(f'  Driver : {d.get(\"driver\",\"N/A\")}'); \
	    print(f'  DNS    : {d.get(\"dns_enabled\",False)}')" 2>/dev/null || true
	@echo ""
	@echo "── Containers du projet sur presse_claude_network ──"
	@podman ps --filter "name=^presse_claude_" -q | while read id; do \
	  name=$$(podman inspect "$$id" --format "{{.Name}}" 2>/dev/null); \
	  ip=$$(podman inspect "$$id" --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" 2>/dev/null); \
	  net=$$(podman inspect "$$id" --format "{{range $$k, $$v := .NetworkSettings.Networks}}{{$$k}}{{end}}" 2>/dev/null); \
	  printf "  %-35s %-16s %s\n" "$$name" "$$ip" "$$net"; \
	done | sort
	@echo ""
	@echo "── Autres réseaux sur la machine (non touchés) ──"
	@podman network ls --format "  {{.Name}}" | grep -v "presse_claude_network" | grep -v "^  podman$$" | head -20

# Tests d'intégration
test:
	@./scripts/integration-test.sh

press-shell:
	podman exec -it $(PREFIX)press bash

server-shell:
	podman exec -it $(PREFIX)server bash

setup-press:
	./scripts/setup-press.sh

register-server:
	./scripts/register-server.sh

webhooks:
	./scripts/setup_forgejo_webhooks.sh

mkcert:
	./scripts/setup-mkcert.sh

dns:
	./scripts/dns-setup.sh

dns-remove:
	./scripts/dns-teardown.sh

clean:
	$(PC) down -v
	./scripts/dns-teardown.sh 2>/dev/null || true
	@echo "⚠  Données supprimées"

# ══════════════════════════════════════════════════════════════════════════════
# ─── PODMAN QUADLETS (systemd-native, remplace podman-compose) ────────────────
# ══════════════════════════════════════════════════════════════════════════════
#
# Tiers de ressources:
#   core   → Traefik + MariaDB + Redis (~1 Go RAM)
#   small  → + Press + Server           (~3 Go)
#   medium → + Garage + Forgejo + Mail  (~4 Go)
#   large  → + Prometheus + Loki + Grafana (~5 Go)
#   gpu    → + Ollama + OpenWebUI       (~9 Go + GPU optionnel)

# ── Build images locales ──────────────────────────────────────────────────────
build-press:
	podman build -t presse_claude_press:latest docker/press

build-server:
	podman build -t presse_claude_server:latest docker/server

# ── Installation ──────────────────────────────────────────────────────────────
quadlets-check:
	@./quadlets/install.sh --check

quadlets-install:
	@./quadlets/install.sh

# Installer par profil (auto-copie + daemon-reload)
quadlets-install-small:
	@./quadlets/install.sh --profile small

quadlets-install-medium:
	@./quadlets/install.sh --profile medium

quadlets-install-large:
	@./quadlets/install.sh --profile large

quadlets-install-gpu:
	@./quadlets/install.sh --profile gpu

# ── Démarrage par tier (ordre croissant) ─────────────────────────────────────
quadlets-start-core:
	systemctl --user start presse-claude-core.target

quadlets-start-small: quadlets-start-core
	systemctl --user start presse-claude-press.target

quadlets-start-medium: quadlets-start-small
	systemctl --user start presse-claude-devtools.target

quadlets-start-large: quadlets-start-medium
	systemctl --user start presse-claude-observability.target

quadlets-start-gpu: quadlets-start-large
	systemctl --user start presse-claude-ai.target

# ── Arrêt (ordre décroissant) ─────────────────────────────────────────────────
quadlets-stop-ai:
	systemctl --user stop presse-claude-openwebui.service presse-claude-ollama.service 2>/dev/null || true

quadlets-stop-monitoring:
	systemctl --user stop presse-claude-observability.target 2>/dev/null || true

quadlets-stop-devtools:
	systemctl --user stop presse-claude-devtools.target 2>/dev/null || true

quadlets-stop-press:
	systemctl --user stop presse-claude-press.target 2>/dev/null || true

quadlets-stop-core:
	systemctl --user stop presse-claude-core.target 2>/dev/null || true

quadlets-stop-all: quadlets-stop-ai quadlets-stop-monitoring quadlets-stop-devtools quadlets-stop-press quadlets-stop-core

# ── Persistance au boot ───────────────────────────────────────────────────────
quadlets-enable-linger:
	loginctl enable-linger $(shell whoami)
	@echo "✓ Services démarreront au boot sans session active"

# Activer les services par profil
quadlets-enable: quadlets-enable-linger
	systemctl --user enable \
	  presse-claude-traefik.service \
	  presse-claude-mariadb.service \
	  presse-claude-redis-cache.service \
	  presse-claude-redis-queue.service \
	  presse-claude-press.service \
	  presse-claude-server.service
	@echo "✓ Profil small activé au boot"

quadlets-enable-medium: quadlets-enable
	systemctl --user enable \
	  presse-claude-garage.service \
	  presse-claude-forgejo.service \
	  presse-claude-stalwart.service

quadlets-enable-large: quadlets-enable-medium
	systemctl --user enable \
	  presse-claude-prometheus.service \
	  presse-claude-loki.service \
	  presse-claude-grafana.service

quadlets-enable-gpu: quadlets-enable-large
	systemctl --user enable \
	  presse-claude-ollama.service \
	  presse-claude-openwebui.service

# ── Monitoring ────────────────────────────────────────────────────────────────
quadlets-status:
	@systemctl --user list-units 'presse-claude-*' --all 2>/dev/null || echo "Aucun service quadlet actif (daemon-reload requis ?)"

quadlets-logs:
	journalctl --user -u 'presse-claude-*' -f

quadlets-logs-core:
	journalctl --user -u presse-claude-mariadb -u presse-claude-redis-cache -u presse-claude-traefik -f

quadlets-logs-press:
	journalctl --user -u presse-claude-press -u presse-claude-server -f

# ── Backup ────────────────────────────────────────────────────────────────────
backup:          ## Backup MariaDB vers S3 (Garage)
	@./scripts/backup-mariadb.sh

backup-dry:      ## Test backup sans écrire
	@./scripts/backup-mariadb.sh --dry-run
