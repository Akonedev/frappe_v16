# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projet

**Presse Claude** — Plateforme SaaS Frappe Press 100% locale sur Docker (dev).
Design complet: `docs/plans/2026-02-18-presse-claude-design.md`
Plan d'implémentation: `docs/plans/2026-02-18-implementation-plan.md`

## Commandes essentielles

```bash
make install         # Installation complète (première fois)
make start           # Démarrer tous les services
make stop            # Arrêter tous les services
make status          # État des containers
make logs            # Logs en temps réel
make press-shell     # Shell dans Press container
make server-shell    # Shell dans server container (Agent)
make setup-press     # Configurer Press Settings après démarrage
make register-server # Enregistrer server container dans Press
make dns             # Ajouter *.press.local dans /etc/hosts
make dns-remove      # Supprimer les entrées DNS
make webhooks        # Configurer webhooks Forgejo → Press (23 repos)
make mkcert          # Générer certificats TLS locaux de confiance (mkcert)
make clean           # Tout arrêter et supprimer les données
```

## Architecture

```
Traefik v3 (:14001 HTTP, :14002 HTTPS)
    ├── press.local → Press dashboard (presse_claude_press)
    ├── *.press.local → Sites clients
    ├── git.press.local → Forgejo
    ├── s3.press.local → Garage S3
    ├── monitor.press.local → Grafana
    └── ai.press.local → Open WebUI

Orchestration:
    presse_claude_press → SSH(:14021) → presse_claude_server
                        → Agent HTTP(:14022)

Infra:
    presse_claude_mariadb  (:14030) — Base de données (MariaDB 10.6)
    presse_claude_redis_*           — Cache + Queue (Redis 7)
    presse_claude_garage   (:14040) — S3 storage (Garage v1.0.0)
```

## Conventions impératives

1. **Préfixe `presse_claude_`** sur tous les containers, volumes, réseaux, images
2. **Ports 14000-14500** uniquement, tous définis dans `.env`
3. **Jamais de valeur en dur** — toujours `${VARIABLE}` depuis `.env`
4. **`.env` jamais commité** (dans `.gitignore`)
5. **Chemins relatifs** dans `compose/*.yml` : utiliser `../` pour remonter à la racine
6. **MariaDB uniquement** pour les sites clients (Press ne supporte pas PostgreSQL)
7. **Lire le design doc** avant toute modification architecturale

## Composants clés

| Fichier | Rôle |
|---|---|
| `compose/infra.yml` | Traefik v3, MariaDB 10.6, Redis 7 |
| `compose/press.yml` | Frappe Press (dashboard SaaS) |
| `compose/server.yml` | Container "server" Ubuntu+SSH+Agent |
| `compose/storage.yml` | Garage S3 (remplace MinIO/AWS S3) |
| `compose/git.yml` | Forgejo v14 (remplace GitHub) |
| `compose/mail.yml` | Stalwart Mail |
| `compose/monitoring.yml` | Prometheus + Grafana + Loki |
| `compose/ai.yml` | Ollama + Open WebUI |
| `docker/server/` | Dockerfile Ubuntu+SSH+bench+agent |
| `docker/press/` | Dockerfile Frappe Press V16 |
| `config/traefik/` | Config statique + TLS |
| `config/garage/` | Config Garage S3 |

## Décisions architecturales

| Décision | Choix | Raison |
|---|---|---|
| Provider server | Generic | Pas de dépendance Hetzner/AWS |
| Provider DNS | Generic | DNS via /etc/hosts |
| S3 storage | Garage v1.0.0 | MinIO en maintenance mode déc. 2025 |
| Git server | Forgejo v14 | Hard fork non-profit actif de Gitea |
| Email | Stalwart + frappe/mail | App officielle Frappe |
| Proxy | Traefik v3 | Service discovery Docker auto |
| Branch Press | master | Pas de branche version-16 dans Press |
| DB sites | MariaDB 10.6 | Seule option supportée par Press |
| Garage keys | Format GKxxxx | Généré par Garage (pas configurable) |
| Press Dashboard | Vue SPA buildé | Build host → `apps/press/press/www/dashboard.html` |
| App Sources | Forgejo (git.press.local) | 24 apps mirrorées depuis GitHub |
| TLS local | mkcert (scripts/setup-mkcert.sh) | Certs de confiance *.press.local |

## Press Dashboard (Vue SPA)

Le dashboard `/dashboard` est une Vue SPA qui doit être **buildée** avant utilisation.

**Rebuild du dashboard (si modifié):**
```bash
# Sur le HOST (240G libres), pas dans le container (disque plein)
mkdir -p /tmp/fake_bench/apps/press /tmp/fake_bench/sites
docker cp presse_claude_press:/home/frappe/frappe-bench/apps/press/dashboard/. /tmp/fake_bench/apps/press/dashboard/
echo '{"socketio_port":9000}' > /tmp/fake_bench/sites/common_site_config.json
(cd /tmp/fake_bench/apps/press/dashboard && yarn install && yarn run build)
# Copier les résultats dans le container
docker cp /tmp/fake_bench/apps/press/press/www/dashboard.html \
  presse_claude_press:/home/frappe/frappe-bench/apps/press/press/www/dashboard.html
docker cp /tmp/fake_bench/apps/press/press/public/dashboard/. \
  presse_claude_press:/home/frappe/frappe-bench/sites/assets/press/dashboard/
```

## Apps Frappe (Tasks 16 + 22 + 24-30)

24 App Sources dans le bench, tous pointant vers Forgejo local:
- **Starter** (gratuit): frappe, crm, helpdesk, lms, wiki, gameplan, builder, print_designer, payments
- **Pro** ($25/mo): + erpnext, hrms, drive, raven
- **Enterprise** ($99/mo): + insights
- **Mail** (Task 22): + mail (branch develop, requiert Python ≥3.14 — non installable avec Python 3.12)
- **Phase 4** (Tasks 24-26): education, hospitality, lending, non_profit, webshop, meeting, llm
- **Phase 5** (Task 29): + frappe_whatsapp (community, branch master)
- **Dépendance helpdesk**: telephony (branch develop, mirroré depuis frappe/telephony)

**Forgejo mirrors** (sync auto depuis GitHub):
```bash
http://git.press.local/frappe/<app_name>   # toutes les 24 apps dont telephony
http://git.press.local/The-Commit-Company/raven
```

**Apps bench server** (24 total):
builder, crm, drive, education, erpnext, frappe, frappe_whatsapp, gameplan,
helpdesk, hospitality, hrms, insights, lending, llm, lms, mail, meeting,
non_profit, payments, print_designer, raven, telephony, webshop, wiki

## Site apps.press.local (Task 30)

Site Frappe de démonstration avec toutes les apps principales installées:
- **URL**: `https://apps.press.local:14002/desk`
- **Apps installées (15)**: frappe, payments, erpnext, hrms, crm, telephony, helpdesk, lms,
  drive, wiki, gameplan, builder, print_designer, raven, insights
- **DB**: `_d3a079634a5614ed` sur presse_claude_mariadb
- **Bench**: `bench-0001-000001-presse_claude_server`

**DNS requis** (ajouter manuellement si `make dns` non exécuté):
```bash
echo '127.0.0.1 apps.press.local' | sudo tee -a /etc/hosts
```

**Redémarrer gunicorn bench après pip install de nouvelles apps:**
```bash
# Dans le server container:
pkill -f 'gunicorn.*8001' || true
BENCH=/home/frappe/benches/bench-0001-000001-presse_claude_server
nohup sudo -u frappe env HOME=/home/frappe \
  $BENCH/env/bin/gunicorn \
  --bind 0.0.0.0:8001 --workers 2 --worker-class=gthread --threads=4 \
  --timeout 120 --chdir $BENCH/sites frappe.app:application \
  >> /tmp/bench-bench-0001-000001-presse_claude_server.log 2>&1 &
```

## TLS local (Task 27)

Certificats mkcert générés pour `*.press.local` — valides jusqu'à 2028:
- `config/traefik/certs/press.local.crt` / `.key` (chargés par Traefik)
- CA: `config/traefik/certs/ca/rootCA.pem` (à importer dans navigateur)
- Régénération: `make mkcert`

## Backup S3 (Task 28)

Press configuré pour sauvegarder vers Garage (S3-compatible):
- Bucket backups: `press-backups` (Garage endpoint: `http://presse_claude_garage:3900`)
- Bucket uploads: `press-uploads`
- Credentials dans `.env`: `GARAGE_ACCESS_KEY`, `GARAGE_SECRET_KEY`

## Routing Traefik (Task 23)

- `*.press.local` → `presse_claude_server:80` (nginx bench, wildcard regex Traefik v3)
- `press.local` → `presse_claude_press:8000` (Press dashboard)
- Config: `config/traefik/dynamic/client-sites.yml`
- **IPs dynamiques** — utiliser les noms de containers Docker (pas d'IPs hardcodées)

**Déploiement site E2E validé (Task 23):**
```
testsite.press.local → frappe + crm installés, agent job Success, HTTP 200
demosite.press.local → Active, HTTP 200
client1.press.local  → Active, HTTP 200
```

**Agent Press↔Server:**
- `local_agent_http: true` dans `press.local/site_config.json`
- Agent URL: `http://presse_claude_server:8000/`
- Circuit breaker: si `Agent Request Failure` bloque, supprimer en DB et reset `next_retry_at`

**Sync manuel des mirrors:**
```bash
./scripts/sync_apps_to_forgejo.sh [app_name]  # sync une app ou toutes
```

## Accès

| URL | Service | Login |
|---|---|---|
| `https://press.local:14002/desk` | Press Admin Desk | Administrator / presse_admin_2024 |
| `https://press.local:14002/dashboard` | Press Vue Dashboard | même |
| `https://git.press.local:14002` | Forgejo | gitadmin / presse_admin_2024 |
| `https://monitor.press.local:14002` | Grafana | admin / admin |
| `https://ai.press.local:14002` | Open WebUI | — |
| `https://apps.press.local:14002/desk` | Site apps démo (15 apps) | Administrator / presse_admin_2024 |
