# Infra (deploy v2)

Ansible + docker compose for staging and prod. Old `deploy/` is the previous setup, frozen until cutover.

Layers on the host:
- `/srv/platform`: caddy, prometheus, alertmanager, grafana, exporters, restic timers. `platform.service`.
- `/srv/hackorum`: the app stack. `hackorum.service`. (plan 3)

## Local setup

    pipx install ansible-core ansible-lint
    cd infra/ansible
    ansible-galaxy collection install -r requirements.yml
    echo '<vault password>' > .vault_pass

## Fresh host

Checklist from a bare box to a monitored one, in order.

1. Hetzner Robot: open a ticket for the outbound port 25 unlock. Check the IP on a blacklist
   checker (e.g. mxtoolbox) before pointing DNS at it. PTR/rDNS comes later (plan 3).
2. Robot firewall is STATELESS. Start from Hetzner's "Webserver" template: it keeps the TCP
   ack/established and ephemeral-port rules that outbound apt, ACME, image pulls and Telegram
   need. Add TCP 25 and UDP 443 (http/3). Do not just list 22/80/443/25, replies to outbound
   connections would be dropped.
3. Boot the rescue system, `lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL` to identify the disks,
   then `installimage`. Essentials (device names may be nvme0n1/nvme1n1 if the SSDs are NVMe):

       DRIVE1 /dev/sda          # SSD 1
       DRIVE2 /dev/sdb          # SSD 2
       # delete the DRIVE line of the 12TB HDD, or installimage builds the RAID over it
       SWRAID 1
       SWRAIDLEVEL 1
       HOSTNAME staging.hackorum.dev
       PART swap swap 4G
       PART /boot ext3 1024M
       PART lvm vg0 all
       LV vg0 root / ext4 all

   Pick Debian 13 (trixie) from the image menu, installimage fills IMAGE. On a UEFI boot
   installimage also wants `PART /boot/efi esp 256M`.
4. Format the HDD once, still in rescue or after first boot. This destroys its contents,
   check ROTA=1 and 12T in lsblk first. Old md superblocks sit at the end of auction disks,
   so wipe first:

       wipefs -a /dev/sdX
       mkfs.ext4 -L bulk -m 0 /dev/sdX

   Ansible mounts it by label at `bulk_root` (/srv/bulk) via `bulk_device` in the inventory.
5. Reboot into the new system. `ssh-keygen -R <ip>`: the rescue host key differs and
   host_key_checking is on.
6. Put the real IP in `inventory/<env>.yml`.
7. Fill EVERY key in the vault with real values before the first run:
   `ansible-vault edit inventory/group_vars/<env>/vault.yml`. Especially:
   - a real ACME email (not example.com)
   - GHCR token: leave empty while ghcr.io/hackorum-dev/hackorum is public (no login
     then). A private package needs a classic token with read:packages.
   - bcrypt hashes: `docker run --rm -it caddy:<tag> caddy hash-password`
   - Telegram bot token and chat id
   - healthchecks.io check URL (period 10m, grace 10m, Telegram integration)

   Vault values must not contain `{{`, `{%` or `{#` (Jinja would try to render them).
8. DNS A records for the env's app, grafana, metrics, mailpit (staging) and mail hosts,
   before platform.yml (Caddy needs them for certificates).
9. Run `bootstrap.yml`, then `platform.yml` (see Playbooks).
10. Checks:
    - Prometheus targets are UP: `https://<grafana_host>/prometheus/targets`
    - a test alert reaches Telegram:
      `docker compose -f /srv/platform/compose/compose.yml exec alertmanager amtool alert add testalert --alertmanager.url=http://localhost:9093`
    - the healthchecks.io watchdog check is green
11. Until the app layer exists, SiteProbeFailing (own site) and SmtpBannerDown fire. Silence them:

        docker compose -f /srv/platform/compose/compose.yml exec alertmanager amtool silence add alertname=~"SiteProbeFailing|SmtpBannerDown" --duration=14d --comment="no app layer yet" --alertmanager.url=http://localhost:9093

Escape hatch: if the HDD is dead or missing, remove `bulk_device` from the inventory to
converge without it (`bulk_root` is then a plain directory on the root fs). With
`bulk_device` set and the disk missing, the mount is the last base task and a
`BulkDiskMissing` alert fires after 5m.

## Playbooks

    ansible-playbook -i inventory/staging.yml playbooks/bootstrap.yml -u root   # once per fresh host
    ansible-playbook -i inventory/staging.yml playbooks/platform.yml

Secrets: `inventory/group_vars/<env>/vault.yml` (loaded automatically), `ansible-vault edit inventory/group_vars/staging/vault.yml`.
Group vars live in `inventory/group_vars/` (next to the inventory files, so ansible loads them).

## Firewall

nftables table `inet hackorum`, input policy drop. Docker publishes `ports:` by
DNAT in the forward path, which this chain never sees: a published port is
public no matter what. Only caddy (80/443) and the mailserver (25) publish.
Everything else is `expose:` on the `edge` network. The Hetzner Robot firewall
is the second layer, set by hand (see Fresh host, stateless).

## Monitoring

Grafana: `https://<grafana_host>`, user admin.
The vault password applies only on the first start (empty data dir), later change it with
`docker compose -f /srv/platform/compose/compose.yml exec grafana grafana cli admin reset-admin-password '<pw>'`.
Datasources and the 4 community dashboards are provisioned from the repo (`roles/platform/`).

Prometheus and Alertmanager UIs: `https://<grafana_host>/prometheus/` and `/alertmanager/`.
Staging: behind the staging basic auth. Prod: metrics basic auth.

`https://<metrics_host>` (metrics basic auth) is what the other host scrapes:
`/node/metrics`, `/cadvisor/metrics`, `/blackbox/metrics`, `/smartctl/metrics`, `/caddy/metrics`,
`/prometheus/federate`. Anything else is 404.
Set `other_host_enabled: true` in the env group_vars once the counterpart host has run platform.yml,
until then its scrape jobs are not rendered.

node_exporter runs on the host network, port 9100 on every interface.
Only nftables (input policy drop) and the Robot firewall keep it private, containers reach it through host-gateway.

Caddy access logs: `/srv/bulk/logs/caddy/access.log`, rolled at 250MiB, 100 kept.

## App layer contract

- Caddy snippets go in `/srv/platform/caddy/sites/*.caddy`. They are imported inside the app host
  block: directives only. A whole new site needs a platform template change.
- Prometheus targets: `/srv/platform/prometheus/targets/*.yml` (file_sd, set `job` and `host` labels).
- Rule files in `/srv/platform/prometheus/rules/` need a Prometheus HUP to load.
- Textfile metrics go in `/srv/platform/textfile`, written atomically (tmp file + mv).
  Metric names are listed in `roles/platform/files/rules/backup.yml`.

## GitHub deploy workflow

One-time setup in the repo settings:
1. Environments `staging` and `prod`. On `prod` add yourself as required reviewer.
   Restrict deployment branches of both Environments to `main`.
2. Secrets on each environment: `SSH_PRIVATE_KEY` (a deploy key whose public half is in
   the vault's `deploy_ssh_public_keys`), `SSH_KNOWN_HOSTS` (`ssh-keyscan <ip>` output),
   `ANSIBLE_VAULT_PASSWORD` (contents of `.vault_pass`).

Generate the key: `ssh-keygen -t ed25519 -f ./gh-deploy -N '' -C github-deploy`.
Store the private half in the `SSH_PRIVATE_KEY` secret, then delete the local copy.
Add the public half to the vault list and re-run `platform.yml --tags base`: it installs
the vault keys into `authorized_keys` (exclusive, the vault list is the full set).

Runs: Actions -> Deploy -> Run workflow, pick environment and scope. `wipe` is staging-only.

Every successful push "Docker Build" on main also deploys `scope=deploy` to staging, but only
when the repository variable `STAGING_AUTO_DEPLOY` is `true`. Set it once staging runs the app layer.
