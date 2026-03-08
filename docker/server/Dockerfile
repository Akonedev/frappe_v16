# docker/server/Dockerfile
# Container "serveur géré" Ubuntu pour Frappe Press
# Simule un VPS Ubuntu sur lequel Press déploie des benches et sites via SSH+Ansible+Agent

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Fix GPG signature validation issues (Docker environment / date drift)
RUN printf 'Acquire::AllowInsecureRepositories "true";\nAcquire::AllowDowngradeToInsecureRepositories "true";\nAcquire::Check-Valid-Until "false";\n' \
    > /etc/apt/apt.conf.d/99docker-insecure

# ── Système de base ──────────────────────────────────────────────────────────
RUN apt-get update -o Acquire::AllowInsecureRepositories=true && apt-get install -y --allow-unauthenticated \
    # SSH server
    openssh-server \
    # Outils système
    sudo \
    curl \
    wget \
    git \
    vim \
    htop \
    jq \
    # Python 3.12 (default on Ubuntu 24.04, required by Frappe v16)
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    # Build deps for frappe Python packages (mysqlclient, etc.)
    pkg-config \
    libmariadb-dev \
    libmariadb-dev-compat \
    # libmagic for frappe/drive python-magic dependency
    libmagic1 \
    libmagic-dev \
    # Node.js 24 setup (Frappe v16 requires Node >= 24)
    ca-certificates \
    gnupg \
    # MariaDB client (pour bench new-site)
    mariadb-client \
    # Redis server (requis par frappe-agent pour les jobs async)
    redis-server \
    # Redis tools
    redis-tools \
    # Nginx (géré par bench)
    nginx \
    # Supervision
    supervisor \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && true

# ── Node.js 24 (Frappe v16 requires Node >= 24) ──────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g yarn && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Utilisateur frappe (UID 1000 — standard Frappe Cloud Hybrid) ─────────────
# Sur Ubuntu 24.04, l'utilisateur 'ubuntu' a UID 1000 par défaut → le supprimer
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash frappe && \
    echo "frappe ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/frappe && \
    chmod 0440 /etc/sudoers.d/frappe && \
    mkdir -p /home/frappe/{benches,archived,.ssh}

# ── SSH server config ─────────────────────────────────────────────────────────
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#AuthorizedKeysFile/AuthorizedKeysFile/' /etc/ssh/sshd_config

COPY sshd_config /etc/ssh/sshd_config.d/frappe.conf

# ── Virtual environment Python pour frappe ───────────────────────────────────
USER frappe
WORKDIR /home/frappe

RUN python3 -m venv /home/frappe/.venv && \
    /home/frappe/.venv/bin/pip install --upgrade pip

# ── frappe-bench CLI ─────────────────────────────────────────────────────────
RUN /home/frappe/.venv/bin/pip install frappe-bench

# ── frappe-agent (depuis source GitHub, pas disponible sur PyPI) ─────────────
# Clone the source to ensure templates/ package data is included (not shipped by pip install)
RUN git clone --depth 1 https://github.com/frappe/agent.git /tmp/agent_src && \
    /home/frappe/.venv/bin/pip install /tmp/agent_src && \
    AGENT_PKG=$(/home/frappe/.venv/bin/python3 -c "import agent; import os; print(os.path.dirname(agent.__file__))") && \
    cp -r /tmp/agent_src/agent/templates "${AGENT_PKG}/" && \
    rm -rf /tmp/agent_src

# ── Permissions finales ───────────────────────────────────────────────────────
USER root
RUN chown -R frappe:frappe /home/frappe && \
    ln -sf /home/frappe/.venv/bin/bench /usr/local/bin/bench || true && \
    ln -sf /home/frappe/.venv/bin/agent /usr/local/bin/agent || true

# Expose SSH et Agent
EXPOSE 22 8000

# ── Nginx config template pour Frappe bench ──────────────────────────────────
COPY frappe-nginx.conf /etc/nginx/conf.d/frappe-bench.conf.template
RUN rm -f /etc/nginx/sites-enabled/default

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
