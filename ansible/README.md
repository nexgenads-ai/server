# NexGenAds Home Server — Ansible Automation

Infrastructure-as-Code for the origin server `server.nexgenads.space`.

This repository now contains two independent layers:

1. **Client/SSH tooling** — `setup.sh`, `setup.ps1`, `servers.conf`, `server-dispatch.sh` (unchanged).
2. **Server provisioning** — this `ansible/` directory.

Ansible converges an Ubuntu server so that it reliably runs:

```
Ubuntu
  +-- Nginx   :80   (reverse proxy)
  |     +-- /jenkins/  -> 127.0.0.1:8080/jenkins/
  |     +-- /grafana/  -> 127.0.0.1:3000       (sub-path mode)
  |     +-- /          -> 127.0.0.1:8090
  +-- Jenkins       (native systemd service, 127.0.0.1:8080)
  +-- Grafana       (native systemd service, 127.0.0.1:3000)
```

Cloudflare (Tunnel, Access, DNS) sits in front of Nginx and is **not** managed by Ansible.

---

## 1. What Ansible does

- Installs and converges **Nginx**, **Jenkins**, and **Grafana** as native systemd services.
- Never converts these services to Docker.
- Preserves existing data and configuration (`/var/lib/jenkins`, `/var/lib/grafana`).
- Backs up config files before changing them (timestamped backups are created by the `template` module when a file changes).
- Validates Nginx (`nginx -t`) before reloading; Grafana restarts only when `grafana.ini` changes.
- Is fully idempotent — safe to run again and again.

## 2. Repository structure

```
ansible/
├── ansible.cfg                  # Ansible client defaults
├── inventory/
│   └── hosts.ini                # home_server group
├── group_vars/
│   └── all.yml                  # all centralized variables
├── playbooks/
│   └── server.yml               # main playbook
└── roles/
    ├── common/                  # apt cache + base packages
    ├── jenkins/                 # Java + official repo + jenkins
    ├── grafana/                 # GPG key + repo + grafana.ini template
    └── nginx/                   # install + site template + validate/reload
```

## 3. Inventory

`ansible/inventory/hosts.ini`:

```ini
[home_server]
home
```

The hostname and SSH user are defined once in `ansible/group_vars/all.yml`
(`ansible_host`, `ansible_user`) so they can be changed in one place.
SSH reaches the server through Cloudflare Access using a `cloudflared`
ProxyCommand (same model as `setup.sh`).

## 4. Roles

| Role | Purpose |
|------|---------|
| `common` | `apt update` + base packages (`curl`, `wget`, `gnupg`, `ca-certificates`, `apt-transport-https`, `software-properties-common`) |
| `jenkins` | Installs `openjdk-17-jre-headless`, adds the official Jenkins APT repo/key, installs Jenkins, starts/enables the service, verifies port 8080. If Jenkins is already installed it is left alone. |
| `grafana` | Adds the official Grafana repo/key, installs Grafana, deploys `grafana.ini` from template (sub-path config), starts/enables the service, verifies port 3000. |
| `nginx` | Installs Nginx, deploys `default.conf.j2`, validates with `nginx -t`, reloads only on change, verifies `/jenkins/`, `/grafana/`, and `/` routes. |

## 5. Installing Ansible

On a Debian/Ubuntu control machine:

```bash
sudo apt update
sudo apt install -y ansible
```

Verify:

```bash
ansible --version
```

## 6. Testing connectivity

Requires `cloudflared` installed and authenticated (see `setup.sh`).

```bash
cd ansible
ansible all -i inventory/hosts.ini -m ping
```

## 7. Running the playbook

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini playbooks/server.yml
```

Safe to run repeatedly. Second and later runs should report mostly `ok`
with no unnecessary restarts.

## 8. Check mode (dry run)

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini playbooks/server.yml --check
```

## 9. Verbose output (troubleshooting)

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini playbooks/server.yml -vv
```

For connection-level debugging use `-vvv` or `-vvvv`.

## 10. Verifying Jenkins

On the server:

```bash
systemctl status jenkins --no-pager
systemctl is-active jenkins
ss -lntp | grep :8080
```

Public URL (behind Cloudflare + Nginx):

```
https://server.nexgenads.space/jenkins/
```

## 11. Verifying Grafana

On the server:

```bash
systemctl status grafana-server --no-pager
systemctl is-active grafana-server
ss -lntp | grep :3000
curl -I http://127.0.0.1:3000
```

Public URL (behind Cloudflare + Nginx):

```
https://server.nexgenads.space/grafana/
```

Expected redirect chain: `/grafana/` -> 302 -> `/grafana/login` -> 200.

## 12. Verifying Nginx

On the server:

```bash
systemctl status nginx --no-pager
nginx -t
ss -lntp | grep :80
```

Expected routes:

```bash
curl -I -H 'Host: server.nexgenads.space' http://127.0.0.1/grafana/
curl -I -H 'Host: server.nexgenads.space' http://127.0.0.1/grafana/login
```

## 13. How Cloudflare fits in

```
Internet
   |
Cloudflare (Tunnel + Access + DNS)
   |
server.nexgenads.space (origin Nginx :80)
   |
   +-- /jenkins/  -> :8080
   +-- /grafana/  -> :3000
   +-- /          -> :8090
```

Cloudflare is an **external** layer. This first version of Ansible manages
only the origin server. Cloudflare Tunnel, Access policies, and DNS are
managed separately (Zero Trust dashboard / `cloudflared`).

## 14. What Ansible does NOT manage

- Cloudflare Tunnel routes, Access policies, or DNS
- SSH server configuration (`sshd_config`)
- Client-side SSH config (`~/.ssh/config`)
- `servers.conf`, `setup.sh`, `setup.ps1`, `server-dispatch.sh`
- Jenkins jobs, credentials, plugins (preserved, never deleted)
- Grafana dashboards and database (preserved, never deleted)
- Docker, Prometheus, Node Exporter, cloudflared (future roles can be added)

## 15. Security hardening in this version

- **Grafana binds to 127.0.0.1 only** (`grafana_bind_address`). Nginx
  proxies to `127.0.0.1:3000`, so public access still works via the
  reverse proxy while Grafana can never be reached directly. To revert
  to binding on all interfaces, change `grafana_bind_address` to `0.0.0.0`.
- Jenkins and Grafana ports are never opened to the public Internet —
  both remain behind Nginx + Cloudflare.

## 16. Notes on server-dispatch.sh

`server-dispatch.sh` was written when Jenkins/Grafana/Prometheus were
Docker containers (`docker exec`). Jenkins and Grafana are now native
systemd services, so the dispatcher is **not compatible** with the current
architecture for those targets. It has been left untouched; a future phase
may replace it with an Ansible-managed dispatcher that targets systemd
units instead of containers.

## 17. Extending later

Add future roles under `roles/` (e.g. `prometheus`, `node_exporter`,
`docker`, `cloudflared`) and list them in `playbooks/server.yml` in the
correct dependency order. No changes to existing roles are required.
