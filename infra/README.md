# Infra (deploy v2)

Ansible + docker compose for staging and prod. Old `deploy/` is the previous setup, frozen until cutover.

Layers on the host:
- `/srv/platform`: caddy, prometheus, alertmanager, grafana, exporters, restic timers. `platform.service`.
- `/srv/hackorum`: the app stack. `hackorum.service`. (plan 3)

## Local setup

    pipx install ansible-core ansible-lint
    pipx inject ansible-core passlib   # or the distro package python3-passlib; password_hash needs it
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
      `sudo docker compose -f /srv/platform/compose/compose.yml exec alertmanager amtool alert add testalert --alertmanager.url=http://localhost:9093`
    - the healthchecks.io watchdog check is green
11. Until the app layer exists, SiteProbeFailing (own site) and SmtpBannerDown fire. Silence them
    (expire it once the app is up, see "First app-layer run"):

        sudo docker compose -f /srv/platform/compose/compose.yml exec alertmanager amtool silence add alertname=~"SiteProbeFailing|SmtpBannerDown" --duration=14d --comment="no app layer yet" --alertmanager.url=http://localhost:9093

Escape hatch: if the HDD is dead or missing, remove `bulk_device` from the inventory to
converge without it (`bulk_root` is then a plain directory on the root fs). With
`bulk_device` set and the disk missing, the mount is the last base task and a
`BulkDiskMissing` alert fires after 5m.

## Playbooks

    ansible-playbook -i inventory/staging.yml playbooks/bootstrap.yml -u root   # once per fresh host
    ansible-playbook -i inventory/staging.yml playbooks/platform.yml

Secrets: `inventory/group_vars/<env>/vault.yml` (loaded automatically), `ansible-vault edit inventory/group_vars/staging/vault.yml`.
Group vars live in `inventory/group_vars/` (next to the inventory files, so ansible loads them).

## App layer vault keys

Add to `inventory/group_vars/<env>/vault.yml` (all `vault_` prefixed). Required in both envs unless noted.

- `rails_master_key`, `secret_key_base`, `umami_app_secret`, `umami_hash_salt`, `google_client_id`,
  `google_client_secret`: copy from old prod `deploy/.env` (RAILS_MASTER_KEY, SECRET_KEY_BASE, UMAMI_*, GOOGLE_*).
- `postgres_password`, `umami_db_password`, `receiver_password`, `app_smtp_password`, `restic_password`: generate.
  `receiver_password` is reachable from the internet (IMAPS, webmail): 20+ random characters, asserted.
- `roundcube_des_key`: exactly 24 characters (`openssl rand -hex 12`), asserted.
- `storagebox_user`, `storagebox_host`: Hetzner Robot. `storagebox_ssh_private_key`: new ed25519 key, public half uploaded to the box.
- `healthchecks_backup_url`, `healthchecks_restore_url`, `healthchecks_monthly_url`: one check each in healthchecks.io.
  `healthchecks_mail_backup_url` is optional (hourly mail backup, empty = no ping).
- Required on prod only: `hackorum_github_token` (old `HACKORUM_GITHUB_TOKEN`) and `ci_deploy_ssh_private_key` (both for the
  orchestrator, asserted), `umami_website_id` (not asserted, but empty = no analytics script on prod).
- Optional: `lineage_api_token` (old `LINEAGE_API_TOKEN`, empty = lineage API off),
  `staging_mail_allowlist`, `staging_reply_override` (staging).

## Firewall

nftables table `inet hackorum`, input policy drop. Docker publishes `ports:` by
DNAT in the forward path, which this chain never sees: a published port is
public no matter what. Only caddy (80/443) and the mailserver publish: 25, and
465/587/993 while `firewall_mail_submission_open` is true (it drives both the
nftables set and the compose `ports:`).
Everything else is `expose:` on the `edge` network. The Hetzner Robot firewall
is the second layer, set by hand (see Fresh host, stateless): it has to allow
465, 587 and 993 too.

## Monitoring

Grafana: `https://<grafana_host>`, user admin.
The vault password applies only on the first start (empty data dir), later change it with
`sudo docker compose -f /srv/platform/compose/compose.yml exec grafana grafana cli admin reset-admin-password '<pw>'`.
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
`scope=deploy` only re-renders `.env` (image tag, secrets), pulls, migrates and restarts. Changes to compose.yml,
templates, mail/postgres config, Caddy snippets or units need `scope=site`.

Every successful push "Docker Build" on main also deploys `scope=deploy` to staging, but only
when the repository variable `STAGING_AUTO_DEPLOY` is `true`. Set it once staging runs the app layer.

The weekly wipe drill (`staging-wipe.yml`, Sundays 03:00 UTC) dispatches `scope=wipe` on staging, but only
when the repository variable `STAGING_WIPE_DRILL` is `true`. Enable it after the first manual wipe drill worked.

## Mail

docker-mailserver 17 (Dovecot 2.4, Rspamd, Valkey, fail2ban) in the app compose stack. Config is rendered by the
`hackorum` role into `/srv/hackorum/compose/mail.env`, `/srv/hackorum/dms/config/`
(`dovecot.cf`, `postfix-main.cf`, `sender-login-app.pcre`, `fail2ban-jail.cf`,
`rspamd/override.d/{multimap,dkim_signing,ratelimit,settings}.conf`) and `/srv/hackorum/dms/rspamd-lua/from_owner.lua`.
System accounts: `receiver@<domain>` (imap_worker_local ingests it) and `app@<domain>` (Rails SMTP, port 587).
`postmaster@` and `dmarc@` forward to the ACME email.

Accounts and aliases have two writers. Ansible writes only the system part, as fragments:
`postfix-accounts.system.cf` and `postfix-virtual.system.cf`. Rails merges them with the mailboxes from
`/admin/mailboxes` into `postfix-accounts.cf`, `postfix-virtual.cf`, `dovecot-quotas.cf` and `sender-login.map`
(`rails mail:render`: on every mailbox change, hourly, at the end of each deploy and after a restore).
On a host where the final files do not exist yet the role copies the fragments, so the mailserver starts without Rails.
Do not edit the final files by hand, the next render overwrites them.

`postfix-main.cf`, `fail2ban-jail.cf`, `dovecot.cf` and the Lua file are only read when the container is created.
The role recreates the mailserver when one of them (or `sender-login-app.pcre`) changes (handler), a restart is not enough.
The first run after this change fails at the secrets assert until the vault has `vault_roundcube_des_key`.

The mail cert is Caddy's: the `mail_host` site in the platform Caddyfile pins the issuer to Let's Encrypt,
so the files are in `acme-v02.api.letsencrypt.org-directory/<mail_host>/` (ZeroSSL would use another dir).
The role waits for the key file before starting the stack. DNS for `mail_host` must exist first.

### DNS per env domain

| name | type | value |
| --- | --- | --- |
| `<domain>` | MX | `10 mail.<domain>.` |
| `<domain>` | TXT | `v=spf1 mx -all` |
| `<selector>._domainkey.<domain>` | TXT | content of the `.public.dns.txt` file below |
| `_dmarc.<domain>` | TXT | `v=DMARC1; p=none; rua=mailto:dmarc@<domain>` |
| PTR of the box IPv4 | PTR | `mail.<domain>` (Hetzner Robot, rDNS) |
| `webmail.<domain>` | A/AAAA | the box (needed before the playbook run, Caddy gets the cert) |
| `_imaps._tcp.<domain>` | SRV | `0 1 993 mail.<domain>.` |
| `_submissions._tcp.<domain>` | SRV | `0 1 465 mail.<domain>.` |
| `_submission._tcp.<domain>` | SRV | `0 1 587 mail.<domain>.` |

Staging: domain `staging.hackorum.dev`, selector `staging`. Prod: domain `hackorum.dev`, selector `prod`.
DMARC stays `p=none` on purpose until phase A's list sending is understood.

### DKIM key

The role runs `setup config dkim domain <domain> selector <selector>` in the running mailserver once
(skipped while the private key exists). Files in `/srv/hackorum/dms/config/rspamd/dkim/`:

    <domain>-<selector>.private          0600, rspamd only
    <domain>-<selector>.public.dns.txt   the TXT value, one line (v=DKIM1; k=rsa; p=...)
    <domain>-<selector>.public.txt       same as a zone file snippet

Read it: `ssh deploy@<host> sudo cat /srv/hackorum/dms/config/rspamd/dkim/<domain>-<selector>.public.dns.txt`.
`rspamd/override.d/dkim_signing.conf` is rendered from the role (not DMS's default: its `use_esld = true`
looks for a key named after the parent domain, so `staging.hackorum.dev` would never be signed). Signing
needs an authenticated submission from the From domain; `check_pubkey` is off, so mail is signed even
before the DNS record exists. To rotate: delete the three files, rerun the role, update DNS.

The key survives the staging wipe drill: `wipe.yml` copies the `dkim/` dir (`cp -a`, owners kept) to
`/srv/platform/restic/dkim-keep` (root only) before deleting `/srv/hackorum` and puts it back before the role runs, so the
role skips generation and the DNS record stays valid. Rotation steps are unchanged (the next wipe copies the new key).

### Checks

Inbound (from outside, after DNS and the Robot firewall allow 25). Postfix wants a resolvable sender
domain and a fully qualified HELO:

    swaks --to receiver@<domain> --from you@<real domain> --helo <fqdn> --server mail.<domain>
    ssh deploy@<host> 'sudo ls /srv/hackorum/data/mail/<domain>/receiver/new /srv/hackorum/data/mail/<domain>/receiver/.Junk/new'

Expect `250 2.0.0 Ok: queued` and one new file. From a home IP it may land in `.Junk` (sender SPF/DMARC fail,
dynamic IP), fine for this check; `X-Spamd-Result` in the file lists the rspamd symbols. Rejects and
deliveries are in `/srv/hackorum/data/mail-logs/mail.log` (`NOQUEUE: reject`, `status=sent`).

Outbound, DKIM and SPF (staging: `TEST_TO` must be on `staging_mail_allowlist`):

    ssh deploy@<host> 'cd /srv/hackorum/compose && sudo docker compose exec -T -e TEST_TO=you@example.com web bin/rails runner "ApplicationMailer.new.mail(to: ENV.fetch(%q(TEST_TO)), subject: %q(dkim test), body: %q(hi)).deliver"'

The received message must have `dkim=pass header.d=<domain>` and `spf=pass` in `Authentication-Results`.
Send one more to a non-allowlisted address on staging: it shows up in mailpit with
`X-Hackorum-Staging-Routed: sink` and is not delivered.

### Subscribing to the lists

Use the pglister web form for `receiver@<domain>` and subscribe to pgsql-hackers, pgsql-bugs and
pgsql-committers. Each confirmation mail lands in the maildir:

    ssh deploy@<host> "sudo sh -c 'cat /srv/hackorum/data/mail/<domain>/receiver/new/*'"

Follow the confirmation link, repeat per list. Then `/admin/imap_sync_states` shows `INBOX` with a growing
`last_uid` and `sudo docker compose -f /srv/hackorum/compose/compose.yml logs imap_worker_local` shows ingests.
`ImapWorkerIdle` fires (weekdays, after 6h without ingest) until the lists are subscribed.

### Mailboxes

Real mailboxes are granted in `/admin/mailboxes`, the owner sets the password in `/settings/mailbox`.
Clients: IMAPS `mail.<domain>:993`, SMTP `mail.<domain>:465` (TLS) or `:587` (STARTTLS), username is the login address.
Webmail: Roundcube at `webmail.<domain>` (sqlite in `data/roundcube`, login is the mail address and mail password).
On staging only mailboxes of admins are rendered.

- Sender checks: a login sends only as its own addresses. Envelope: `SPOOF_PROTECTION=1` (Postfix), with
  `postfix-main.cf` adding `sender-login-app.pcre` so `app@` may use any sender of the domain.
  `From:` header: the rspamd prefilter `FROM_OWNER_CHECK` (`from_owner.lua`) against `sender-login.map`, `app@` exempt.
  It fails closed: without the map no mailbox login can send (`rails mail:render` writes it), `app@` still can.
  rspamd notices a changed map within a few minutes, so a new alias cannot send right away.
  Both this rule and the rate limit run in rspamd: while rspamd is down Postfix accepts mail without them
  (`milter_default_action = accept`, DMS default), only the envelope check is left.
  The rule has a test, `luajit roles/hackorum/files/tests/from_owner_test.lua <rendered lua>` (CI runs it).
- DMS runs authenticated mail through the `dkim` group only. `override.d/settings.conf` re-enables
  `FROM_OWNER_CHECK` and the ratelimit symbols for it. If they do not fire (see checks), the fallback is
  `RSPAMD_CHECK_AUTHENTICATED=1` in `mail.env.j2` instead of that file (full scanning of outbound mail).
- Rate limit: `mail_user_rate_limit` recipients per hour per login (100), `app@` exempt. Over the limit is a 4xx.
  It counts per SASL login, and DMS lets an alias log in with the mailbox password: every alias is its own bucket.
- fail2ban: jails `dovecot` and `postfix`, 10 failed logins in 10 minutes ban the address for an hour.
  The postfix jail runs in `mode = auth`: with the DMS default (`extra`) rejected recipients count too, and a list
  server delivering to a removed address would get itself banned. Private ranges are ignored
  (`fail2ban-jail.cf`): webmail and app containers log in from there, and if docker ever shows the gateway address
  instead of the client the result is no bans, not everybody banned.
  `setup fail2ban` lists bans, `setup fail2ban unban <ip>` removes one. `mail_fail2ban_enabled: false` turns it off.
- Quotas: `dovecot-quotas.cf` from the admin page.
- DMS finds the account of an alias, and the quota of an account, with an unanchored `grep` and takes the first
  line that matches. With logins where one is the tail of another (`ian`, `brian`) the wrong line can win: `ian`'s
  alias would get `brian`'s password and `brian` could send as it, or a mailbox would get another one's quota.
  Rails renders shorter logins first (dotted before plain at the same length), so the first match is the right one,
  and refuses a login that is the tail of a system account or ends with one (`iver`, `myapp`).
  A hand-added account in a system fragment has to respect the same rule.
- Deleting a mailbox keeps its maildir. Remove it before the delete in the admin page, or the next owner of that
  login gets the old mail: `docker compose ... exec mailserver rm -rf /var/mail/<domain>/<login>`.
- The maildirs live in `hackorum_mail_data` (default `data/mail`, NVMe). Moving them is that variable plus an rsync.

### Mailbox checks

After the first run with the ports open (staging first). DNS (`webmail`, SRV), `vault_roundcube_des_key` and the
Robot firewall (465, 587, 993) come before the playbook run.

    C="sudo docker compose -f /srv/hackorum/compose/compose.yml"
    $C exec mailserver postconf smtpd_sender_login_maps      # ends with sender-login-app.pcre
    $C exec mailserver rspamadm configdump ratelimit | grep -A3 user
    $C exec mailserver rspamadm configdump settings | grep symbols_enabled
    $C exec mailserver fail2ban-client status
    $C exec mailserver cat /tmp/docker-mailserver/sender-login.map
    $C logs mailserver | grep -i 'from_owner\|lua.*error'      # nothing

1. Grant a mailbox to an admin, set a password: the login shows up in `postfix-accounts.cf`.
2. Log in from outside: IMAPS 993, SMTP 465 and 587
   (`swaks --server mail.<domain> --port 465 --tls-on-connect --auth-user <login> ...`).
3. Mail from outside arrives at the login address and at an alias.
4. Mail to an outside address has DKIM and SPF passing (`Authentication-Results`).
5. `swaks --from <other>@<domain>`: `553 5.7.1`. `swaks --from <login> --header 'From: security@<domain>'`:
   `From address not owned by login`. `--from <alias>` with the same header address: accepted.
6. Site mail (`app@` as `noreply@`) still goes out: password reset to an allowlisted address.
7. 7 failed logins from an outside IP: `fail2ban-client status dovecot` lists that IP and no `172.` address,
   `grep 'rip=' /srv/hackorum/data/mail-logs/mail.log` shows public addresses.
   A private address there means docker hides the client: set `mail_fail2ban_enabled: false` and fix that first.
8. Webmail: log in, send, receive. `ls -l /srv/hackorum/data/roundcube/` has `sqlite.db`.
9. Add an alias, `/admin/imap_sync_states` keeps advancing (ingestion survives the reload).
10. After the nightly restore: admin mailboxes are rendered, a non-admin one granted on prod is not.
11. Quota 1 MB, send 2 MB: rejected, ingestion unaffected.
12. `receiver@` in a mail client and the webmail, read a few mails, ingestion keeps going.
13. `mail_user_rate_limit: 3` on staging: the 4th recipient within the hour gets a 4xx, `app@` does not.
14. Move `sender-login.map` away: a mailbox login cannot send, a password reset mail still goes out.
    `rails mail:render` puts it back.
15. A few mails from outside to an address that does not exist: `fail2ban-client status postfix` stays empty
    (rejected recipients must not ban, list servers hit removed addresses).

On prod after cutover, once the first hourly snapshot exists: `restic snapshots --tag nightly --latest 1` and
`restic snapshots --tag mail-hourly --latest 1` both answer, the two `forget --dry-run` calls (see Backups) list only
their own tag, and one `restore.yml` drill on staging from `hackorum.dev` goes through (it used to pick the hourly
snapshot as `latest`, which has no dumps).

### Notes

- Staging INBOX autoexpunges after 30 days (`dovecot.cf`). Prod keeps everything.
- `receiver@` can be opened in a mail client (IMAPS 993) or the webmail with `receiver_password`.
  Never with client-side filters: the worker only ingests what stays in INBOX.
  Folders also via doveadm in the mailserver container
  (`docker compose -f /srv/hackorum/compose/compose.yml exec mailserver ...`):
  `doveadm mailbox status -u receiver@<domain> messages '*'`,
  `doveadm fetch -u receiver@<domain> 'uid hdr.from hdr.subject' mailbox Junk all`,
  `doveadm move -u receiver@<domain> INBOX mailbox Junk uid <uid>` (the worker only reads INBOX).
- Message size limit 50 MB (`POSTFIX_MESSAGE_SIZE_LIMIT`, DMS also uses it for the Dovecot quota_mail_size).
- `dovecot.cf` sets `ssl = yes` and `auth_allow_cleartext = yes` for imap_worker_local (plain IMAP on 143
  inside the compose network, not published). Dovecot 2.4 with DMS 17's `ssl = required` would refuse it.
- First boot logs `chgrp/chmod: cannot access .../spool-postfix/{maildrop,public}`: DMS permission fixup
  running before it creates the empty state dirs. Harmless, gone after the first restart.
- postfix_exporter mounts `data/mail-state/spool-postfix` (showq socket is `public/showq`) and `data/mail-logs`.

## Backups

Role `backup`: restic over sftp to a Hetzner Storage Box. Repo `sftp:storagebox:hackorum-restic` (relative: inside the Storage Box home dir, its root is not writable), config in
`/srv/platform/restic/restic.env` (0600), restic cache on the HDD (`/srv/bulk/restic-cache`).

### Storage Box setup (once)

1. Order the box in Robot, enable SSH support. Either use the main user or add a sub-account with its own
   directory (preferred, vault `storagebox_user` is then `uNNNNNN-subN`).
2. `ssh-keygen -t ed25519 -N '' -f storagebox_key`, upload the public half:
   `cat storagebox_key.pub | ssh-copy-id -p 23 -s -i /dev/stdin <user>@<user>.your-storagebox.de`
   (or paste it into the sub-account's authorized keys in Robot).
3. Vault (`inventory/group_vars/<env>/vault.yml`): `vault_storagebox_user`, `vault_storagebox_host`
   (`<user>.your-storagebox.de`), `vault_storagebox_ssh_private_key` (the private half), `vault_restic_password`.
   Staging and prod use the same repo and the same password.

The role writes `/root/.ssh/storagebox`, a `Host storagebox` block into `/root/.ssh/config`, and runs
`restic init` if `restic cat config` fails. Keep the restic password somewhere outside the repo too:
without it the backups are unreadable.

### healthchecks.io checks

Create the checks and put the ping URLs (no trailing slash) into the vault:
- `vault_healthchecks_backup_url`: period 1 day, grace 3 hours (nightly at 02:00 + up to 5 min delay).
- `vault_healthchecks_restore_url`: period 2 days, grace 3 hours (staging restore: Mon-Sat 04:00, Sundays are the wipe drill or nothing).
- `vault_healthchecks_monthly_url`: period 1 month, grace 1 day.
- `vault_healthchecks_mail_backup_url` (optional, prod): period 1 hour, grace 1 hour.

Scripts ping `<url>/start`, `<url>` on success and `<url>/fail` on failure.

### What runs when

Timers exist on both envs but are enabled only if `backup_enabled` (prod true, staging false).
- `hackorum-backup.timer`: daily 02:00 (+ up to 5 min). `backup.sh`: `pg_dump -Fc -Z0` of `hackorum` and `umami`
  into `<dumps root>/daily`, `restic backup` (dumps, mail, dms, compose dirs, caddy/grafana/prometheus data,
  roundcube data, without mail-logs), `restic forget --tag nightly --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune`
  on Sundays, writes `/srv/platform/textfile/backup.prom` (`hackorum_backup_*`).
- `hackorum-mail-backup.timer`: hourly at :30. `mail_backup.sh`: `restic backup --tag mail-hourly` of the maildirs,
  `restic forget --tag mail-hourly --keep-last 24` (no prune, the Sunday run does that), writes `mail_backup.prom`.
  `MailBackupStale` fires after 3 hours without a success (restic exit 3, files that vanished in the live maildir,
  counts as success). The two `forget` calls are limited to their own tag:
  check once with `--dry-run` that neither lists a snapshot of the other.
- `hackorum-restic-check.timer`: Saturday 03:00, `restic_check.sh` (`restic check --read-data-subset=10%`); a failure
  pings `vault_healthchecks_backup_url/fail`, so it shows up on the backup check.
- `hackorum-monthly-dumps.timer`: 1st of the month 02:15, public/private SQL dumps into `<dumps root>/public` and
  `<dumps root>/private` (public is served on `dumps_host`).

Manual run and inspection:

    sudo systemctl start hackorum-backup.service
    sudo journalctl -u hackorum-backup.service -e
    cat /srv/platform/textfile/backup.prom
    sudo bash -c 'set -a; . /srv/platform/restic/restic.env; restic snapshots'

On staging (timers off) a manual `sudo /srv/platform/restic/backup.sh` adds a staging-host snapshot and writes
`backup.prom`, which nothing refreshes there: `BackupStale` fires 26h later. Remove it after the test
(`sudo rm /srv/platform/textfile/backup.prom`) or run `site.yml --tags backup`: the role deletes `backup.prom` where
`backup_enabled` is false and `restore.prom` where `restore_enabled` is false.

### Old prod pusher (temporary, until cutover)

So staging can restore prod data before cutover, `infra/scripts/oldprod-push-dump.sh` runs on the old server and
pushes a nightly dump into the same repo with `--host oldprod` (staging's `backup_source_host: oldprod` matches;
switch it to `hackorum.dev` after cutover and remove the cron).
1. Check free disk space on the old box first. A `-Z0` dump of the 24GB DB may be larger than the DB. The script
   keeps one dump at a time under `/srv/bulk/hackorum/dumps/daily` and deletes it after the push.
2. Install restic >= 0.16 (`restic version`; `--retry-lock` needs 0.16, repo format v2 needs 0.14; old distro packages
   are older, then take the static binary from the GitHub release), copy the storagebox key to `/root/.ssh/storagebox`,
   add the `Host storagebox` block to `/root/.ssh/config`, create `/root/oldprod-restic.env` (0600) with
   `RESTIC_REPOSITORY` and `RESTIC_PASSWORD`.
3. Install the script as `/root/oldprod-push-dump.sh` (set `OLD_DEPLOY_DIR` if the checkout is not
   `/root/hackorum/deploy`), run once by hand, confirm with `restic snapshots --host oldprod`.
4. Cron: `0 2 * * * /root/oldprod-push-dump.sh >> /var/log/oldprod-push-dump.log 2>&1`.
Sundays it also prunes its own snapshots (`--keep-daily 7`); nothing else prunes before cutover.

At cutover the old public monthly dumps (old `pgdumps` docker volume, `public/`) are not on the new box and not in restic.
Copy them to `/srv/bulk/hackorum/dumps/public/` on the new box, or let the next monthly run (1st, 02:15) make new ones.

## Restore (new box from zero)

1. `ansible-playbook -i inventory/<env>.yml playbooks/bootstrap.yml -u root`
2. DNS first: point the A records of `app_host`, `mail_host`, `grafana_host`, `metrics_host` (prod also `umami_host`
   and `dumps_host`, staging `mailpit_host`) at the new box BEFORE `platform.yml`/`site.yml`. Caddy needs them for the
   certificates, and `site.yml` waits at most 5 min for the `mail_host` cert, then fails.
   Let's Encrypt rate limits (5 certs per week for the same name) are why restic keeps `data/caddy` (prod snapshots
   only, staging takes no backups). When rebuilding prod more than once a week, put the old certs back before
   `platform.yml`:

       ansible-playbook -i inventory/prod.yml playbooks/platform.yml --tags base   # installs restic
       ansible-playbook -i inventory/prod.yml playbooks/site.yml --tags backup     # restic.env, storage box key
       sudo bash -c 'set -a; . /srv/platform/restic/restic.env; restic restore latest --host hackorum.dev --tag nightly --target / --include /srv/platform/data/caddy'

3. `platform.yml`, then `site.yml` (the backup role needs the storage box key and restic password in the vault;
   it finds the existing repo, no init).
   On prod run `site.yml` with `-e backup_enabled=false` until the restore is done: the hourly mail backup would
   otherwise snapshot the empty new maildir within the hour, and that would be the newest mail snapshot.
4. `ansible-playbook -i inventory/prod.yml playbooks/restore.yml -e from_host=hackorum.dev`
   (optionally `-e snapshot=<id>`; with a snapshot id `from_host` is not needed). On prod this also restores
   the maildirs and `dms` (mail identity, DKIM keys); on staging it does not (`RESTORE_MAIL=0`, staging keeps its own).
   `latest` is the newest `nightly` snapshot. The maildirs come from the newest snapshot that has them, normally
   an hourly one; `-e mail_snapshot=<id>` picks another (`restic snapshots --tag mail-hourly`). With `-e snapshot=<id>`
   and no `mail_snapshot` they come from that snapshot.
   `-e restore_mail=0|1` overrides that. Run it right after `site.yml`: the prod backup timer is on from then, and a
   02:00 run in between makes the empty new DB the latest `hackorum.dev` snapshot (then use `-e snapshot=<id>` of the
   last good one).
5. The run ends with `restore ok from <host> (<snapshot>) in <N>s`. Then the mail checks (Mail > Checks).

`restore.sh` stops the app services the compose file has (web, jobs, imap_worker_local, umami, orchestrator on prod),
restores the latest dumps from `<dumps root>/daily`, drops and
recreates `hackorum` and `umami` (umami objects are owned by `umami`), drops the queue/cache/cable DBs, runs
`db:prepare`, on staging `staging:sanitize` and a receiver INBOX purge, starts everything, waits for `/up`,
runs `mail:render` (the restored DB has other mailboxes than the files on disk),
writes `/srv/platform/textfile/restore.prom` and pings `vault_healthchecks_restore_url`.
While it runs, an Alertmanager silence (3h, expired at the end, best effort) mutes `SiteProbeFailing`, `TargetDown`,
`SmtpBannerDown`, `MailTlsPortDown`, `WebmailDown` and `ImapWorkerIdle`. `RestoreDrill*` alerts are never silenced.

## Staging drills

- Nightly restore: `hackorum-restore.timer`, Mon-Sat 04:00 local, on staging only (`restore_enabled`). It runs
  `restore.sh --from-host <backup_source_host>` (`oldprod` until cutover, then `hackorum.dev`). Reboots are at 06:30
  (`unattended_reboot_time`) so they do not cut a restore.
- Sunday wipe drill: `staging-wipe.yml` (03:00 UTC) dispatches Deploy with `scope=wipe`, which runs `wipe.yml`:
  guard (staging only, `confirm_wipe` = inventory hostname), marker file, stop `hackorum.service`,
  `docker compose down -v --rmi all`, fail if a `hackorum` project container is still there, keep the DKIM key (Mail >
  DKIM key), delete `/srv/hackorum` (dumps on the HDD, platform stack and Grafana stay), DKIM key back,
  re-apply the `hackorum` and `backup` roles, `restore.sh`. The marker makes the timer skip if it fires within 6 hours.
  Runs only when the repo variable `STAGING_WIPE_DRILL` is `true`.
- Metrics: `hackorum_restore_last_status`, `_last_run_timestamp_seconds`, `_duration_seconds` (textfile
  `restore.prom`). Alerts `RestoreDrillFailed` (status != 0) and `RestoreDrillStale` (no run for 50h).
  Healthchecks: `vault_healthchecks_restore_url`.
- `RestoreDrillFailed`: `sudo journalctl -u hackorum-restore -e` (the last line says `restore failed at: <command>`).
  The app layer may be half restored; just fix the cause and re-run `restore.yml`. For a wipe drill the log is in the
  Deploy workflow run.

### First app-layer run (staging)

In this order:
1. Old prod's umami must not be newer than the pinned `images_app.umami` (umami migrations are forward-only, a newer
   dump breaks the older umami). In the old `deploy/` dir: `docker compose exec umami grep -m1 '"version"' /app/package.json`.
2. Old-prod pusher installed and one `oldprod` snapshot in the repo (Backups > Old prod pusher). Staging has
   `restore_enabled: true`, so the first `site.yml` enables the 04:00 restore timer; until the snapshot exists every
   run fails (`RestoreDrillFailed`, restore healthcheck).
3. Google Cloud console, OAuth client of `google_client_id`: add the redirect URI
   `https://staging.hackorum.dev/auth/google_oauth2/callback`, else Google login on staging fails (redirect_uri_mismatch).
4. DNS (A records, Mail > DNS per env domain), then `site.yml`.
5. Once `/up` answers, expire the 14-day "no app layer yet" silence (Fresh host step 11):

       sudo docker compose -f /srv/platform/compose/compose.yml exec -T alertmanager amtool --alertmanager.url=http://localhost:9093 silence query
       sudo docker compose -f /srv/platform/compose/compose.yml exec -T alertmanager amtool --alertmanager.url=http://localhost:9093 silence expire <id>

6. Subscribe `receiver@` to the lists (Mail > Subscribing). `ImapWorkerIdle` fires until then.
7. First restore by hand:

       ansible-playbook -i inventory/staging.yml playbooks/restore.yml -e from_host=oldprod

   Expect `restore ok ... in Ns` (note N as the baseline), real data on staging, `/admin/imap_sync_states` empty and
   then one `INBOX` row once the worker reconnects, and:

       sudo docker compose -f /srv/hackorum/compose/compose.yml exec db psql -U hackorum -d hackorum_production_queue -c 'select count(*) from solid_queue_jobs'

8. The restore timer is on since step 4 (`systemctl list-timers | grep hackorum`). Then the wipe drill:

       ansible-playbook -i inventory/staging.yml playbooks/wipe.yml -e confirm_wipe=staging.hackorum.dev

   Expect `restore ok`, a gap in `up{job="hackorum_web"}`, Grafana up throughout, the same DKIM `.public.dns.txt` as
   before. Then set `STAGING_WIPE_DRILL=true`.
