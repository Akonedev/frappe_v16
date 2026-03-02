# Configuration Stalwart

Stalwart génère et persiste sa configuration dans le volume `presse_claude_stalwart_data`.
Le fichier `config.toml` présent dans ce répertoire est un template de démarrage,
copié dans le container via le Dockerfile ou monté en volume.

## Avertissement sécurité

Le champ `[authentication.fallback_admin].secret` dans `config.toml` est un mot de passe
admin en clair. **Changer cette valeur avant tout déploiement non-dev.**

## Récupérer la config courante depuis le container

```bash
podman exec presse_claude_stalwart cat /opt/stalwart/etc/config.toml
```

## Accès admin UI

- URL HTTP directe : `http://127.0.0.1:14060`
- URL via Traefik  : `https://mail.press.local:14002`
- Login            : `admin` / mot de passe défini dans `config.toml` (`fallback_admin.secret`)

> Les credentials sont aussi dans `.env` si la variable `STALWART_ADMIN_PASSWORD` est définie.

## Backup de la config

```bash
podman exec presse_claude_stalwart cat /opt/stalwart/etc/config.toml \
  > config/stalwart/config.toml.backup
```

## Régénérer un mot de passe admin sécurisé

```bash
# Générer un mot de passe fort
openssl rand -base64 24

# Mettre à jour config.toml.secret puis redémarrer le container
podman restart presse_claude_stalwart
```
