# NexGenAds Home Server — Ansible Automation

Infrastructure-as-Code (IaC) for the origin server **`server.nexgenads.space`**
using **Ansible**.

This repository contains two independent layers that do **not** depend on
each other:

| Layer | Files | What it does |
|-------|-------|--------------|
| **Client / SSH tooling** | `setup.sh`, `setup.ps1`, `servers.conf`, `server-dispatch.sh` | Configures your laptop/PC to reach the server via Cloudflare Access SSH |
| **Server provisioning** | `ansible/` (this directory) | Idempotently configures the server: Nginx + Jenkins + Grafana + Prometheus + Node Exporter |

> The client tooling is **untouched** by Ansible. Ansible only manages the
> origin server, not your local SSH config.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [How the pieces work together](#2-how-the-pieces-work-together)
3. [What Ansible does (and does not)](#3-what-ansible-does-and-does-not)
4. [Directory structure](#4-directory-structure)
5. [Prerequisites](#5-prerequisites)
6. [Configuration files](#6-configuration-files)
7. [Quick start — install Ansible](#7-quick-start--install-ansible)
8. [Testing connectivity](#8-testing-connectivity)
9. [Dry run (check mode)](#9-dry-run-check-mode)
10. [Run the playbook (real changes)](#10-run-the-playbook-real-changes)
11. [Idempotency — running it again](#11-idempotency--running-it-again)
12. [Troubleshooting / verbose output](#12-troubleshooting--verbose-output)
13. [Verifying the stack after deployment](#13-verifying-the-stack-after-deployment)
14. [Role-by-role walkthrough](#14-role-by-role-walkthrough)
15. [Variables reference](#15-variables-reference)
16. [Cloudflare's role](#16-cloudflares-role)
17. [Safety guarantees](#17-safety-guarantees)
18. [What is NOT managed](#18-what-is-not-managed)
19. [Security hardening applied](#19-security-hardening-applied)
20. [Notes on server-dispatch.sh](#20-notes-on-server-dispatchsh)
21. [Extending the setup later](#21-extending-the-setup-later)

---

## 1. Architecture

```
                              PUBLIC INTERNET
                                    |
                                    v
                               CLOUDFLARE
                    (Tunnel + Access + DNS, managed separately)
                                    |
                     cloudflared tunnel -> HTTPS
                                    |
                                    v
                        ORIGIN SERVER (Ubuntu 24.04)
                                    |
                               NGINX  :80
                          (reverse proxy, TLS offload at CF)
                                    |
               +--------------------+----------------------+
               |                    |                      |
               v                    v                      v
          /jenkins/             /grafana/                /
               |                    |                    |
               v                    v                    v
        localhost:8080       localhost:3000         localhost:8090
        (Jenkins,            (Grafana,             (root application)
         native systemd)      native systemd)
                                    |
                                    | PromQL (loopback)
                                    v
                             Prometheus  127.0.0.1:9090
                                    |
                                    | HTTP scrape (loopback)
                                    v
                             Node Exporter 127.0.0.1:9100
```

**Port map**

| Public URL | Nginx location | Upstream | Service |
|------------|----------------|----------|---------|
| `https://server.nexgenads.space/` | `/` | `http://127.0.0.1:8090` | Root application |
| `https://server.nexgenads.space/jenkins/` | `/jenkins/` | `http://127.0.0.1:8080/jenkins/` | Jenkins |
| `https://server.nexgenads.space/grafana/` | `/grafana/` | `http://127.0.0.1:3000` | Grafana (sub-path mode) |

**Internal ports (never exposed publicly)**

| Port | Service | Bind |
|------|---------|------|
| `9090` | Prometheus | `127.0.0.1` only |
| `9100` | Node Exporter | `127.0.0.1` only |

All services run as **native systemd services** on the same host. Nothing
is containerized. Prometheus and Node Exporter are reachable only over the
loopback interface and are **not** routed through Nginx.

---

## 2. How the pieces work together

1. A user hits `https://server.nexgenads.space/grafana/`.
2. **Cloudflare** terminates the TLS connection, applies Access policies,
   and forwards the request through the Cloudflare Tunnel.
3. The tunnel (cloudflared) forwards the request to **Nginx** on port 80.
4. **Nginx** matches the `/grafana/` location and reverse-proxies to
   **Grafana** on `127.0.0.1:3000`.
5. Grafana (with `serve_from_sub_path = true`) answers under its sub-path
   and redirects `/grafana/` → `/grafana/login` → HTTP 200.

Jenkins works the same way under `/jenkins/`, and the root application
under `/`.

**Monitoring data flow** (all loopback, never public):

```
Linux Server
     |  system metrics
     v
Node Exporter (127.0.0.1:9100)
     |  HTTP scrape
     v
Prometheus (127.0.0.1:9090)
     |  PromQL
     v
Grafana (127.0.0.1:3000)  ->  /grafana/ through Nginx + Cloudflare
     |
     v
Server Metrics dashboard
```

---

## 3. What Ansible does (and does not)

### Ansible does

- Install and **converge** Nginx, Jenkins, Grafana, Prometheus, and Node
  Exporter as native systemd services.
- Manage `/etc/nginx/sites-available/default`, `/etc/grafana/grafana.ini`,
  `/etc/prometheus/prometheus.yml`, and systemd units via Jinja2 templates.
- Provision Prometheus as a Grafana datasource and import a Server Metrics
  dashboard (CPU, memory, disk, network, system) through Grafana's
  declarative provisioning directory.
- Preserve existing data (`/var/lib/jenkins`, `/var/lib/grafana`,
  `/var/lib/prometheus`) — it **never deletes** them.
- Validate Nginx with `nginx -t` **before** reloading and Prometheus with
  `promtool check config` **before** reloading.
- Restart services **only when their config actually changes**.
- Back up changed config files automatically (timestamped backups).
- Run safely over and over again (idempotent).

### Ansible does NOT do

- Convert services to Docker.
- Touch Cloudflare (Tunnel, Access, DNS).
- Modify your local `~/.ssh/config`.
- Delete Jenkins/Grafana jobs, credentials, plugins, dashboards, or data.
- Expose Prometheus or Node Exporter publicly.
- Manage firewall rules (not in this first version).

---

## 4. Directory structure

```
ansible/
├── ansible.cfg                 # Ansible client configuration
├── inventory/
│   ├── hosts.ini               # host definition (SSH endpoint + user)
│   └── group_vars/
│       └── all.yml             # all centralized variables (single source of truth)
├── playbooks/
│   └── server.yml              # main playbook (common -> jenkins -> node_exporter -> prometheus -> grafana -> nginx)
└── roles/
    ├── common/
    │   ├── tasks/main.yml      # apt update + base packages
    │   └── handlers/main.yml
    ├── jenkins/
    │   ├── tasks/main.yml      # install / converge Jenkins (native)
    │   ├── handlers/main.yml
    │   └── defaults/main.yml
    ├── node_exporter/
    │   ├── tasks/main.yml      # install / converge Node Exporter (loopback only)
    │   ├── handlers/main.yml
    │   ├── templates/node-exporter.service.j2
    │   └── defaults/main.yml
    ├── prometheus/
    │   ├── tasks/main.yml      # install / converge Prometheus (loopback only)
    │   ├── handlers/main.yml   # promtool check config, then reload
    │   ├── templates/prometheus.yml.j2
    │   ├── templates/prometheus.service.j2
    │   └── defaults/main.yml
    ├── grafana/
    │   ├── tasks/main.yml      # install / converge Grafana (native) + datasource/dashboard provisioning
    │   ├── handlers/main.yml
    │   ├── templates/grafana.ini.j2
    │   ├── templates/prometheus-datasource.yml.j2
    │   ├── templates/dashboards.yml.j2
    │   ├── templates/server-metrics-dashboard.json.j2
    │   └── defaults/main.yml
    └── nginx/
        ├── tasks/main.yml      # install + deploy site + verify
        ├── handlers/main.yml   # validate + reload
        ├── templates/default.conf.j2
        └── defaults/main.yml
```

---

## 5. Prerequisites

### Control machine (your laptop/PC)

- Linux, macOS, or WSL2 (Windows)
- **Ansible** installed (see [Quick start](#7-quick-start--install-ansible))
- **cloudflared** installed and authenticated, so SSH through Cloudflare
  Access works (run `setup.sh` once — it installs cloudflared and the
  SSH config automatically)
- SSH credentials for `home@server.nexgenads.space`
- `sudo`/become credentials for the `home` user (root escalation)

### Target server

- Ubuntu 24.04 LTS (or compatible Debian-based distro)
- `home` user with password and sudo rights
- SSH reachable through Cloudflare Access

---

## 6. Configuration files

### `inventory/hosts.ini`

```ini
[home_server]
home ansible_host=server.nexgenads.space ansible_user=home
```

- `home` = inventory name (what Ansible calls the host internally)
- `ansible_host` = real SSH hostname
- `ansible_user` = SSH login user

> Change the endpoint here if the server moves; everything else references
> the variables in `group_vars/all.yml`.

### `inventory/group_vars/all.yml`

Central variables used by every role — hostname, ports, sub-paths, repo
URLs, key locations. Change them **here**, not inside the roles.

### `ansible.cfg`

Default inventory, role path (`./roles`), host-key checking (kept **on**),
SSH keep-alive/control options, and privilege-escalation defaults.

### SSH connection

Ansible reaches the server through Cloudflare Access SSH, using the same
`ProxyCommand` that `setup.sh` writes into `~/.ssh/config`:

```yaml
ansible_ssh_common_args: >-
  -o ProxyCommand="cloudflared access ssh --hostname %h"
```

`%h` is expanded by OpenSSH to the target hostname.

---

## 7. Quick start — install Ansible

### Ubuntu / Debian (control machine)

```bash
sudo apt update
sudo apt install -y ansible
ansible --version
```

### macOS

```bash
brew install ansible
ansible --version
```

### Verify Ansible picks up this project's config

```bash
cd ansible
ansible --version | grep "config file"
# should print: .../ansible/ansible.cfg
```

---

## 8. Testing connectivity

From inside the `ansible/` directory:

```bash
ansible all -i inventory/hosts.ini -m ping
```

You should see:

```
home | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

If it fails, check that `cloudflared` is running and authenticated, and
that your SSH credentials are valid.

---

## 9. Dry run (check mode)

`--check` shows what *would* change **without changing anything**:

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini playbooks/server.yml --check
```

If your user/password authentication is required:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/server.yml \
  --check --ask-pass --ask-become-pass
```

Verification tasks (service status, ports, HTTP checks) are read-only and
are forced to run even in check mode, so you get a full validation preview.

---

## 10. Run the playbook (real changes)

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini playbooks/server.yml
```

With password prompts:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/server.yml \
  --ask-pass --ask-become-pass
```

**Expected first-run behavior**

- `common`: installs base packages
- `jenkins`: installs Java + Jenkins (if missing), starts the service
- `node_exporter`: installs Node Exporter (if missing), starts the service
- `prometheus`: installs Prometheus (if missing), deploys `prometheus.yml`,
  starts the service
- `grafana`: installs Grafana (if missing), deploys `grafana.ini`,
  provisions the Prometheus datasource + Server Metrics dashboard
- `nginx`: installs Nginx, deploys the site config, validates + reloads

Role order matters: **backends (Jenkins, Node Exporter, Prometheus, Grafana)
are configured before Nginx** so the proxy can route to them.

---

## 11. Idempotency — running it again

Run the same playbook a second time:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/server.yml
```

Expected output: mostly `ok`, **no** package re-installs, **no** service
restarts (unless a managed config file actually changed). This is what
makes the setup safe to re-run after manual drift or after upgrading
Ansible itself.

---

## 12. Troubleshooting / verbose output

| Need | Command |
|------|---------|
| Task-level detail | `ansible-playbook -i inventory/hosts.ini playbooks/server.yml -v` |
| Connection + SSH command | `... -vv` |
| Full debug (module args, SSH EXEC lines) | `... -vvv` |
| Maximal debugging | `... -vvvv` |
| Force a specific config | `ANSIBLE_CONFIG=$(pwd)/ansible.cfg ansible-playbook ...` |
| See what variables a host has | `ansible-inventory -i inventory/hosts.ini --list` |

Example:

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini playbooks/server.yml -vv
```

---

## 13. Verifying the stack after deployment

### All services active

```bash
systemctl is-active nginx
systemctl is-active jenkins
systemctl is-active grafana-server
systemctl is-active prometheus
systemctl is-active node-exporter
```

### Listening ports

```bash
ss -lntp | grep -E ':80|:8080|:3000|:9090|:9100'
```

### Prometheus + Node Exporter

```bash
# Node Exporter metrics (loopback only)
curl -s http://127.0.0.1:9100/metrics | grep node_cpu_seconds_total

# Prometheus readiness
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090/-/ready

# Prometheus sees Node Exporter as UP
curl -s http://127.0.0.1:9090/api/v1/targets
```

### Grafana datasource + dashboard

```bash
ls -l /etc/grafana/provisioning/datasources/
ls -l /etc/grafana/provisioning/dashboards/
```

The **Prometheus** datasource points at `http://127.0.0.1:9090` and the
**Server Metrics** dashboard is loaded from provisioning (General folder).
Existing dashboards are not touched.

### Nginx configuration valid

```bash
nginx -t
```

### Nginx routing (with the correct virtual-host header)

```bash
curl -I -H 'Host: server.nexgenads.space' http://127.0.0.1/
curl -I -H 'Host: server.nexgenads.space' http://127.0.0.1/jenkins/
curl -I -H 'Host: server.nexgenads.space' http://127.0.0.1/grafana/
curl -I -H 'Host: server.nexgenads.space' http://127.0.0.1/grafana/login
```

Expected Grafana chain:

```
GET /grafana/          -> 302
Location: /grafana/login
GET /grafana/login     -> 200 OK
```

### Jenkins

```bash
systemctl status jenkins --no-pager
ss -lntp | grep :8080
```

Public URL: `https://server.nexgenads.space/jenkins/`

### Grafana

```bash
systemctl status grafana-server --no-pager
ss -lntp | grep :3000
curl -I http://127.0.0.1:3000
```

Public URL: `https://server.nexgenads.space/grafana/`

> The playbook itself performs all these checks automatically at the end
> of each role and fails loudly if something is wrong.

---

## 14. Role-by-role walkthrough

### `common`

- Runs `apt update` (cached for 1 hour to stay fast and idempotent).
- Installs base packages required by the other roles:
  `curl`, `wget`, `gnupg`, `ca-certificates`, `apt-transport-https`,
  `software-properties-common`, `python3-apt`.

### `jenkins`

1. Checks whether `jenkins` is already installed.
2. **If missing:** installs Java (`openjdk-17-jre-headless`), downloads the
   official Jenkins signing key, adds the official APT repo, installs
   Jenkins.
3. **If already installed:** skips installation entirely — existing jobs,
   credentials, plugins, and config under `/var/lib/jenkins` are preserved.
4. Ensures `jenkins.service` is enabled + started.
5. Verifies: service active, port `8080` listening.

### `node_exporter`

1. Creates the `node_exporter` system user.
2. **If the binary is missing:** downloads the official release archive
   (checksum-verified), extracts it into `/opt/node_exporter`.
3. **If already installed:** skips download/extract (converge, don't
   rebuild).
4. Deploys the `node-exporter.service` systemd unit bound to
   `127.0.0.1:9100`.
5. Ensures the service is enabled + started.
6. Verifies: service active, port `9100` bound, `/metrics` returns
   `node_cpu_seconds_total`.

### `prometheus`

1. Creates the `prometheus` system user + config/data directories
   (`/etc/prometheus`, `/var/lib/prometheus`).
2. **If the binary is missing:** downloads the official release archive
   (checksum-verified), extracts it into `/opt/prometheus`.
3. Deploys `/etc/prometheus/prometheus.yml` from `prometheus.yml.j2` with a
   `node` scrape job targeting Node Exporter over loopback.
4. Deploys the `prometheus.service` systemd unit bound to `127.0.0.1:9090`.
5. Handler: runs `promtool check config` **before** reloading — if
   validation fails, the reload never happens.
6. Ensures the service is enabled + started.
7. Verifies: service active, port `9090` bound, `/-/ready` → 200, and the
   `node` scrape target reports UP.

### `grafana`

1. Checks whether `grafana` is already installed.
2. **If missing:** adds the official Grafana GPG key + APT repo, installs
   Grafana.
3. Deploys `/etc/grafana/grafana.ini` from `grafana.ini.j2` (sub-path mode,
   loopback-only bind). Original file is backed up automatically on change.
4. Provisions the **Prometheus datasource** and **Server Metrics dashboard**
   via `/etc/grafana/provisioning/` (datasources + dashboards providers).
   Existing dashboards, users, plugins, and the database are untouched.
5. Restarts `grafana-server` **only if config or provisioning changed**.
6. Ensures the service is enabled + started.
7. Verifies: service active, port `3000` listening, local HTTP responds,
   datasource + dashboard provisioning files present.

### `nginx`

1. Installs `nginx`.
2. Deploys `/etc/nginx/sites-available/default` from `default.conf.j2`
   (routes `/`, `/jenkins/`, `/grafana/`). Original is backed up on change.
3. Ensures the `sites-enabled/default` symlink exists.
4. Handler: runs `nginx -t` **before** reloading — if validation fails,
   the reload never happens.
5. Verifies: service active, port `80`, `/grafana/` → 302 →
   `/grafana/login` → 200, plus the root route.

---

## 15. Variables reference

All defined once in `inventory/group_vars/all.yml`:

| Variable | Value | Purpose |
|----------|-------|---------|
| `server_hostname` | `server.nexgenads.space` | Public hostname used by Nginx and Grafana |
| `server_user` | `home` | Primary Linux user |
| `application_port` | `8090` | Root application upstream port |
| `nginx_port` | `80` | Nginx listen port |
| `jenkins_port` | `8080` | Jenkins listen port |
| `jenkins_subpath` | `/jenkins/` | Jenkins URL prefix |
| `jenkins_java_package` | `openjdk-17-jre-headless` | Java runtime for Jenkins |
| `grafana_port` | `3000` | Grafana listen port |
| `grafana_bind_address` | `127.0.0.1` | Grafana bind (loopback only) |
| `grafana_subpath` | `/grafana/` | Grafana URL prefix |
| `grafana_root_url` | `https://server.nexgenads.space/grafana/` | Grafana public root URL |
| `grafana_prometheus_url` | `http://127.0.0.1:9090` | Prometheus URL for the Grafana datasource |
| `grafana_prometheus_datasource_name` | `Prometheus` | Grafana datasource name |
| `grafana_prometheus_datasource_uid` | `prometheus` | Grafana datasource UID (referenced by the dashboard) |
| `grafana_server_metrics_dashboard_uid` | `nexgenads-server-metrics` | Server Metrics dashboard UID |
| `prometheus_service` | `prometheus` | Prometheus systemd service |
| `prometheus_version` | `3.13.2` | Prometheus release version |
| `prometheus_bind_address` | `127.0.0.1` | Prometheus bind (loopback only) |
| `prometheus_port` | `9090` | Prometheus listen port |
| `prometheus_config_dir` | `/etc/prometheus` | Prometheus config directory |
| `prometheus_data_dir` | `/var/lib/prometheus` | Prometheus TSDB directory (preserved) |
| `prometheus_checksum` | `sha256:0e8c…be6f` | Official release checksum (sha256sums.txt) |
| `node_exporter_service` | `node-exporter` | Node Exporter systemd service |
| `node_exporter_version` | `1.12.1` | Node Exporter release version |
| `node_exporter_bind_address` | `127.0.0.1` | Node Exporter bind (loopback only) |
| `node_exporter_port` | `9100` | Node Exporter listen port |
| `node_exporter_checksum` | `sha256:b51d…84e63` | Official release checksum (sha256sums.txt) |

---

## 16. Cloudflare's role

```
Internet
   |
Cloudflare (Tunnel + Access + DNS)   <-- managed in Cloudflare dashboard
   |
server.nexgenads.space (origin Nginx :80)
```

Cloudflare is the **external entry layer** and is deliberately **not**
managed by Ansible in this version:

- **Tunnel** — cloudflared daemon on the server; routes
  `server.nexgenads.space` to Nginx.
- **Access** — login/authorization in front of the public apps.
- **DNS** — the public hostname records.

The Ansible code focuses 100% on the **origin** (Ubuntu + Nginx + Jenkins
+ Grafana).

---

## 17. Safety guarantees

The server was already working before Ansible was introduced. The playbook
is designed to **never break it**:

- If Jenkins/Grafana/Nginx/Prometheus/Node Exporter already exist →
  **converge**, don't rebuild.
- `/var/lib/jenkins`, `/var/lib/grafana`, and `/var/lib/prometheus` are
  **never deleted**.
- Jenkins jobs, credentials, plugins, Grafana dashboards/databases, and
  Prometheus time-series data are preserved.
- Nginx is reloaded only after `nginx -t` passes; Prometheus is reloaded
  only after `promtool check config` passes.
- Grafana restarts only when `grafana.ini` or provisioning files change.
- Grafana provisioning only adds a **new** datasource and dashboard — it
  never deletes or overrides existing dashboards.
- Changed config files get a timestamped backup first.
- Prometheus and Node Exporter bind to loopback only; nothing is exposed
  publicly.
- Nothing is containerized.

---

## 18. What is NOT managed

- Cloudflare Tunnel routes, Access policies, DNS
- SSH server configuration (`sshd_config`)
- Client-side `~/.ssh/config`
- `servers.conf`, `setup.sh`, `setup.ps1`, `server-dispatch.sh`
- Jenkins jobs, credentials, plugins
- Grafana dashboards (manually created ones) and database
- Docker, cloudflared, firewall rules (future roles)

---

## 19. Security hardening applied

- **Grafana binds to `127.0.0.1` only** — public traffic always flows
  through Nginx, never directly to Grafana. Revert by setting
  `grafana_bind_address: 0.0.0.0`.
- **Prometheus binds to `127.0.0.1:9090` only** — not routed through Nginx,
  not reachable publicly.
- **Node Exporter binds to `127.0.0.1:9100` only** — system metrics never
  exposed publicly.
- **Jenkins and Grafana ports are never exposed publicly** — both sit
  behind Nginx + Cloudflare.
- **Host key checking stays enabled** in `ansible.cfg`.
- **Checksum-verified downloads** — Prometheus and Node Exporter archives
  are verified against the official `sha256sums.txt` before extraction.
- **Hardenend systemd units** — `NoNewPrivileges`, `PrivateTmp`,
  `ProtectSystem=strict`, `ProtectHome=read-only` on both monitoring units.
- **Dedicated system users** — `prometheus` and `node_exporter` run with
  `nologin` shells, no home directory.
- Package repos are pinned with `signed-by` keyring files.

---

## 20. Notes on server-dispatch.sh

`server-dispatch.sh` was written when Jenkins/Grafana/Prometheus were
Docker containers (it ran `docker exec ...`). Those services are now managed
differently: Jenkins, Grafana, and Node Exporter run as **native systemd
services**, and Prometheus was previously a **snap** package
(`snap.prometheus.prometheus`) that this repo replaces with a native
systemd service (the role stops and disables the snap first). The dispatcher
is therefore **not compatible** with the current architecture for those
targets. It has been **left untouched** on purpose. A future phase may
replace it with an Ansible-managed dispatcher that targets systemd units
instead of containers.

---

## 21. Extending the setup later

To add services (Docker, cloudflared, backup automation, firewall):

1. Create a new role, e.g. `roles/docker/` (tasks, handlers, defaults,
   templates as needed).
2. Add it to `playbooks/server.yml` in dependency order
   (backends before Nginx).
3. Add its variables to `inventory/group_vars/all.yml`.

Existing roles are modular and self-contained, so no changes to them are
required.
