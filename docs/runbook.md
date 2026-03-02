# Runbook — Presse Claude

## Démarrage rapide

```bash
make quadlets-start-medium   # Services de base
make quadlets-start-large    # + Monitoring
make status                  # Vérifier l'état
```

## Disaster Recovery

### Scénario 1 — Container crashé

```bash
systemctl --user restart presse-claude-<service>.service
# Ou pour tous:
make quadlets-start-medium
```

### Scénario 2 — MariaDB corrompu

```bash
# 1. Arrêter Press et Server
systemctl --user stop presse-claude-press.service presse-claude-server.service
# 2. Restaurer le dernier backup
podman exec -i presse_claude_mariadb mysql -u root -p${MARIADB_ROOT_PASSWORD} < /tmp/backup.sql
# 3. Redémarrer
systemctl --user start presse-claude-press.service presse-claude-server.service
```

### Scénario 3 — Perte volume Garage S3

```bash
# Garage S3 est stateless côté config (garage.toml)
# Les données sont dans le volume presse_claude_garage_data
# Si volume perdu: réinitialiser avec make webhooks + reconfigurer Press Settings S3
```

### Scénario 4 — Certificats TLS expirés

```bash
make mkcert    # Régénérer certificats *.press.local (valides 2 ans)
# Redémarrer Traefik pour recharger
systemctl --user restart presse-claude-traefik.service
```

## Diagnostics

### Logs en temps réel

```bash
journalctl --user -u presse-claude-press.service -f
journalctl --user -u presse-claude-server.service -f
make quadlets-logs
```

### Tester les endpoints

```bash
./scripts/integration-test.sh
curl -k https://press.local:14002/api/method/frappe.ping
```

### Vérifier les jobs Press

```bash
# Dans le container Press:
podman exec -it presse_claude_press bash
bench --site press.local execute frappe.utils.background_jobs.get_workers_info
```

### MariaDB

```bash
podman exec -it presse_claude_mariadb mysql -u root -p${MARIADB_ROOT_PASSWORD}
SHOW DATABASES;
SHOW PROCESSLIST;
```

## Contacts & ressources

- Frappe Press docs: https://github.com/frappe/press
- Frappe framework: https://frappeframework.com/docs
- Podman Quadlets: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
