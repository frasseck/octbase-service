# octbase-service

Operations toolkit for running **one Octbase stack per client** across the
ocete.ch production host(s). It implements the stack-per-tenant model
recommended in the app repo's `docs/hosting-concept.md` (§5 Model A / §16 O1);
the multi-host model is [`docs/fleet-concept.md`](docs/fleet-concept.md):

- every client gets a **dedicated Linux account** `oct-<name>` running its own
  rootless-podman stack (Postgres + API + frontend + mobile), capped by a
  **systemd user-slice** (memory/CPU/tasks) and a **disk quota** — both
  ledger-managed, changeable at any time (`set-resources.yml`),
- each instance is **pinned to one inventory host** (`host:` in its ledger
  entry); every per-client playbook scopes itself to that host, and
  `migrate-host.yml` moves an instance between hosts,
- a **subdomain** `<name>.ocete.ch` is routed by that host's edge reverse
  proxy to the client's frontend port (DNS entries are created manually),
- a **git-versioned ledger** (`ledger/clients/*.yml`) is the single source of
  truth for who the clients are, which edition they booked, add-ons, seats,
  resources, placement — and it directly drives the Ansible playbooks,
- **monitoring** aggregates the app repo's `check-health.sh` plus per-client
  disk usage across all client stacks every 5 minutes and alerts on state
  changes; **fleet backups** dump + restore-test every client nightly,
- all of it is driven by **Ansible playbooks run from a local admin machine**.

```
            Internet                         production host
               │
   DNS: <name>.ocete.ch ──▶ edge reverse proxy (Caddy, root-managed)
                                │  includes /etc/octbase/edge/<name>.caddy
                                ▼
                     127.0.0.1:<frontend_port>
                                │
              ┌─────────────────┴──────────────────┐
              │ Linux user oct-<name>  (rootless)   │
              │   ~/octbase/         (app checkout) │
              │   podman-compose project "octbase"  │
              │   postgres · api · frontend · mobile│
              │   systemd --user unit: octbase      │
              └─────────────────────────────────────┘
```

Because each client runs in its own user namespace, every stack uses the same
compose project name (`octbase`) and the same container names — only the
**host ports** must be unique, and the ledger allocates those. All ports bind
to `127.0.0.1`; nothing but the edge proxy is reachable from outside.

## Repository layout

| Path | Purpose |
|---|---|
| `ledger/clients/*.yml` | **The client ledger** — one file per client, committed to git |
| `ledger/ledger.py` | Ledger CLI: `new`, `list`, `validate`, `next-ports` |
| `inventory/hosts.yml` | The production host(s) Ansible connects to |
| `inventory/group_vars/all/main.yml` | Platform-wide defaults (domain, SMTP relay, source path, …) |
| `inventory/group_vars/all/vault.yml` | Ansible Vault: the SMTP relay password (`vault.yml.sample` documents it) |
| `playbooks/create-instance.yml` | Create **or update** a client instance from its ledger entry |
| `playbooks/sync-instance.yml` | Sync an existing instance's code to an app-repo branch (default `main`), rebuild + restart |
| `playbooks/remove-instance.yml` | Back up and remove a client instance (needs `confirm=`) |
| `playbooks/migrate-instance.yml` | Move an existing installation to its own client account and/or a new domain (same host) |
| `playbooks/migrate-host.yml` | Move a client instance to **another host** (staged via the admin machine) |
| `playbooks/suspend-instance.yml` | Stop a `status: suspended` client non-destructively; domain answers 503 |
| `playbooks/set-max-users.yml` | Set `OCTBASE_MAX_USERS` for a client and restart its stack |
| `playbooks/set-resources.yml` | Apply a client's memory/CPU/tasks caps + disk quota, no redeploy |
| `playbooks/install-monitoring.yml` | Install the fleet monitor (script + systemd timer) on every host |
| `playbooks/install-backup.yml` | Install the nightly fleet backup (script + systemd timer) on every host |
| `playbooks/templates/` | `.env`, systemd user unit + slice drop-in, edge Caddy vhost templates |
| `playbooks/files/podman-compose.client.yml` | Production compose override (see below) |
| `monitoring/monitor-all.sh` | Root-level aggregator that probes every client stack (health + disk) |
| `monitoring/octbase-monitor.{service,timer}` | systemd units for the 5-minute monitor run |
| `backup/backup-fleet.sh` | Nightly per-client DB dump + restore test + attachments/`.env` archive |
| `backup/octbase-fleet-backup.{service,timer}` | Root systemd units for the nightly fleet backup |
| `backup/backup-octbase.sh` | Legacy daily DB backup (claude account) for the resident dev/demo stacks |
| `backup/octbase-backup.{service,timer}` | systemd user units for that legacy nightly run |
| `docs/fleet-concept.md` | The multi-instance / multi-host model: placement, resources, quotas, backups, moves |
| `docs/platform-overview.md` | The whole platform: all four repos, host topology, release flow, doc map |
| `docs/consistency-register.md` | Cross-repo contracts that must stay in sync + known drift, with a per-release checklist |
| `docs/production-readiness-plan.md` | The ordered plan to production: launch blockers, structural phase, go/no-go gate for client #1 |
| `docs/security-data-protection-concept.md` | Security & data-protection concept (standards mapping, open items) |

## Prerequisites

**Admin machine** (where you run the playbooks):
- ansible-core ≥ 2.16 (with the `ansible.posix` collection), `rsync`,
  `openssl`, Python 3 with PyYAML (Ansible brings it). The playbooks use
  `ansible.builtin.systemd_service`, which does not exist before core 2.15 —
  don't trust older docs that claimed 2.14 worked.
- A checkout of the app repo (`frasseck/octbase.git`) at the release you want
  to ship. Its path is `octbase_src` in `inventory/group_vars/all/main.yml`.
- SSH root access to the production host (or a sudo user — then set
  `ansible_user` accordingly and add `rsync_path: sudo rsync` to the sync task).

**Production host:** `podman`, `podman-compose`, `loginctl` (systemd),
`rsync`, `curl`. The edge reverse proxy (Caddy) is managed outside this repo;
this tooling only *generates* per-client vhost snippets for it.

## The ledger

One YAML file per client in `ledger/clients/`. The file name is the client
`name`, which is also the subdomain label and the Linux account suffix.
See `ledger/clients/_example.yml.sample` for the full field reference:

```yaml
name: acme                 # → acme.ocete.ch, Linux user oct-acme
display_name: ACME GmbH
contact: it@acme.example
edition: business          # team | business | enterprise
jira_import: true          # bookable add-on; only honored for business
max_users: 25              # → OCTBASE_MAX_USERS
registered: 2026-07-10
status: active             # active | suspended | removed
app_version: "1.0.1"       # → OCTBASE_APP_VERSION stamp
host: prod                 # inventory host the instance runs on
disk_quota_gb: 10          # account disk quota (enforced where fs allows, always monitored)
resources:                 # optional — account caps (systemd user slice);
  memory_max: 4G           #   omitted keys use client_default_resources
  cpu_quota: 300%          #   from group_vars
ports:                     # unique across the fleet, allocated by ledger.py
  frontend: 8110
  api: 8111
  postgres: 8112
notes: ""
```

Ledger CLI (run from the repo root):

```bash
./ledger/ledger.py new acme --display "ACME GmbH" --edition business \
    --jira-import --max-users 25 --contact it@acme.example   # scaffolds the file, allocates ports
./ledger/ledger.py list        # table of all clients
./ledger/ledger.py validate    # names, editions, port collisions, add-on rules
./ledger/ledger.py next-ports  # next free port triplet
```

The ledger holds **no secrets**. Per-client secrets (DB password, JWT secret,
encryption keys) are generated on first deployment and live only in the
client's `.env` on the server (mode 0600).

## Runbooks

### Onboard a new client

```bash
./ledger/ledger.py new acme --display "ACME GmbH" --edition business --jira-import \
    --max-users 25 --contact it@acme.example
./ledger/ledger.py validate
git add ledger/clients/acme.yml && git commit -m "ledger: onboard acme"

ansible-playbook playbooks/create-instance.yml -e client=acme
```

The playbook then prints the two **manual** steps:
1. **DNS**: create `acme.ocete.ch` → A/AAAA record for the production host.
2. **Edge proxy**: the playbook wrote `/etc/octbase/edge/acme.caddy`
   (`acme.ocete.ch { reverse_proxy 127.0.0.1:8110 }`). Include it from the
   edge Caddyfile (`import /etc/octbase/edge/*.caddy` once, then just reload).

Verify: `curl -s https://acme.ocete.ch/health` → `{"status":"ok",…}`.

### Change a client's configuration (edition, add-on, version, seats)

Edit the ledger file, commit, and re-run the create playbook — it is
idempotent and re-applies the ledger-managed settings without touching
secrets or data. Platform-wide values from `inventory/group_vars/all/main.yml`
(SMTP relay, trusted proxies, retention days) are re-synced into the client's
`.env` on the same run — so after changing one of those, re-run the playbook
for **every** active client:

```bash
ansible-playbook playbooks/create-instance.yml -e client=acme
```

### Sync an instance to a branch (main)

`create-instance.yml` deploys whatever `octbase_src` (a working tree on the
admin machine) currently holds. To instead pull an instance's code straight
from a branch of the app repo — the way the demo was fed by `git pull` before
it became a managed client — use `sync-instance.yml`:

```bash
# sync the demo (/home/oct-demo/octbase) to origin/main, rebuild + restart
ansible-playbook playbooks/sync-instance.yml -e client=demo

# a different branch for one run
ansible-playbook playbooks/sync-instance.yml -e client=demo -e octbase_branch=release_v15
```

It clones/updates `octbase_branch` (default `main`, from `octbase_repo`) into
a cache on the **admin machine**, rsyncs that tree into `~/octbase` (same
excludes as create — `.git`, `.env`, `pgdata*`, `attachments`, `node_modules`,
`prompts`),
refreshes the compose override, then **always** rebuilds the images, restarts
the stack and gates on `/health` — app code is baked into the images at build
time, so every sync run causes a brief restart, even when the tree is already
at the branch tip.

It is **update-only**: it refuses if the instance isn't provisioned yet, and it
never touches the `.env`, secrets, data, ports, or ledger-managed settings. To
also re-apply ledger/platform `.env` settings, run `create-instance.yml`; to
bump the `OCTBASE_APP_VERSION` stamp, edit the ledger and run
`create-instance.yml`. Make sure the branch is at or above the running schema
version before syncing a live instance.

### Set OCTBASE_MAX_USERS

By default the value comes from the ledger (edit `max_users`, commit, run):

```bash
ansible-playbook playbooks/set-max-users.yml -e client=acme
```

For an ad-hoc override (extra-vars beat the ledger), pass it explicitly —
and update the ledger afterwards so it stays the source of truth:

```bash
ansible-playbook playbooks/set-max-users.yml -e client=acme -e max_users=40
```

The playbook updates the client's `.env`, restarts the stack (brief downtime,
containers are recreated so the env change takes effect) and re-checks
`/health`.

> Note: the API enforces `OCTBASE_MAX_USERS` as of app release_v14 (403
> `USER_LIMIT_REACHED` on user creation and invitation create/accept; every
> non-deleted account counts, including the admin). Unset, the app defaults to
> 5; the compose override's fail-closed default is 1, so the ledger value must
> reach `.env`. The same release adds two upload limits with product defaults
> baked into `env.j2`: `OCTBASE_MAX_UPLOAD_MB` (10 MB per file) and
> `OCTBASE_MAX_USER_STORAGE_MB` (512 MB stored per user); edit a client's
> `.env` and restart for one-off deals — they are deliberately not
> ledger-managed.

### Give or take resources (memory / CPU / tasks / disk)

Edit the client's `resources:` block and/or `disk_quota_gb` in the ledger,
commit, and apply — no redeploy, no restart, takes effect immediately:

```bash
ansible-playbook playbooks/set-resources.yml -e client=acme
```

Ad-hoc overrides (update the ledger afterwards):

```bash
ansible-playbook playbooks/set-resources.yml -e client=acme \
    -e memory_max=4G -e cpu_quota=300% -e disk_quota_gb=20
```

The caps apply to the whole `oct-acme` account (systemd slice
`user-<uid>.slice`): all four containers plus image builds. The disk quota is
enforced via filesystem user quota where the host filesystem has `usrquota`
enabled (the playbook warns when it can't) — and is *always* monitored: the
fleet monitor flags the client DEGRADED (state-change mail) at 90% usage.
Verify live: `systemctl show user-<uid>.slice -p MemoryCurrent,MemoryMax`.

### Suspend / resume a client

Suspend keeps account, data and secrets, stops the stack, deregisters
monitoring and serves 503 at the edge:

```bash
# 1) set status: suspended in ledger/clients/acme.yml, commit
ansible-playbook playbooks/suspend-instance.yml -e client=acme -e confirm=acme
# 2) reload the edge proxy (manual, root)
```

Resume: set `status: active`, commit, `create-instance.yml` (restarts the
stack, re-registers monitoring, rewrites the real vhost), reload the edge.
Note: suspended instances are not in the monitor/backup registry — take a
manual backup first if the suspension may end in offboarding.

### Move an instance to another host

Placement is the `host:` field in the ledger (see `inventory/hosts.yml` for
valid names; the model is `docs/fleet-concept.md`). To move client `acme`
from `prod` to `prod2`:

```bash
# 1) edit ledger/clients/acme.yml → host: prod2, validate, commit
# 2) octbase_src must be at the client's release (schema ≥ the source's)
ansible-playbook playbooks/migrate-host.yml \
    -e client=acme -e source_host=prod -e confirm=acme
```

The playbook freezes and dumps the source, stages DB + attachments + `.env`
through the **admin machine** (no host↔host SSH trust needed), provisions the
target via `create-instance.yml` (fresh account, ports from the ledger,
slice caps, quota), restores the data, carries the JWT/SCM/MFA secrets, and
health-gates. Then, manually: repoint the DNS record (lower its TTL before
the move), reload both edge proxies, and remove the stopped source account
after verification. Downtime spans from the freeze to the health check plus
DNS propagation.

### Offboard a client

```bash
ansible-playbook playbooks/remove-instance.yml -e client=acme -e confirm=acme
```

This stops the stack, takes a **final backup** (`pg_dump` + attachments +
`.env`) to `/var/backups/octbase/` on the host, deletes the Linux account and
all its data, and removes the edge snippet and monitor registration
(`skip_backup=true` skips the backup). Then, manually: remove the DNS record,
reload the edge proxy, and set `status: removed` in the ledger file (keep the
file — it is the historical record).

### Move an installation to a new user / domain

```bash
# target = a normal ledger entry (create it first when adopting a legacy stack)
ansible-playbook playbooks/migrate-instance.yml -e client=<name>
```

Moves an **existing** installation onto its own `oct-<name>` account — either
adopting a legacy shared-account stack (e.g. the public demo, prepared in
`ledger/clients/demo.yml`) into the client model, or renaming a managed
client to a new name/domain. The playbook asks for the source domain, account
and path (or takes `-e source_fqdn= -e source_user= -e source_dir=
-e confirm=<name>`), then: dumps the source DB and stages `.env` +
attachments to `/var/backups/octbase/` (kept as safety copy), stops the
source (data left in place for manual removal after verification), provisions
the target via `create-instance.yml`, restores DB + attachments, carries the
JWT/SCM/MFA secrets, gates on `/health`, and cuts the edge over — this is the
one playbook allowed to edit the root Caddyfile (adds the
`import /etc/octbase/edge/*.caddy` line, retires the source's hardcoded
vhost block, `caddy validate` + reload). Downtime spans stop → health-check;
the target's code (from `octbase_src`) must be at or above the source's
schema version. Full runbook and the demo-specific steps: the
`migrate-instance` skill.

## Monitoring

Install once (and re-run after changing monitor settings in group_vars):

```bash
ansible-playbook playbooks/install-monitoring.yml
```

What it does on each host:
- installs the app repo's `octbase-operations/check-health.sh` (two-layer
  container + application probe, JSON output) to `/usr/local/lib/octbase/`,
- installs `monitor-all.sh`, which every 5 minutes (systemd timer
  `octbase-monitor.timer`) iterates all registered clients
  (`/etc/octbase/clients.d/*.conf`, maintained by the playbooks), runs
  `check-health.sh` inside each client's rootless-podman context,
  probes the public edge (`https://<name>.ocete.ch/health`), and checks
  each client's **disk usage** (cached `du` of the home directory, refreshed
  hourly) against its ledger quota — ≥ `disk_alert_pct` (default 90%) flags
  the client DEGRADED,
- writes the fleet state to `/var/lib/octbase-monitor/status.json`
  (machine-readable, one object per client: `OK | DEGRADED | DOWN`, plus
  `disk_bytes` / `disk_pct`),
- on any **state change** sends a mail via the local `sendmail` to
  `alert_email` (set it in `inventory/group_vars/all/main.yml`) and always logs to
  the journal: `journalctl -u octbase-monitor.service`.

Ad-hoc fleet status: `sudo /usr/local/lib/octbase/monitor-all.sh --print`.

The public-edge probe can be disabled per client while its DNS/edge setup is
still pending: set `monitor_edge_probe: false` in the client's ledger file and
re-run `create-instance.yml` (remove the field and re-run once the client is
live). The global default is `edge_probe` in `inventory/group_vars/all/main.yml`.

For external ("is the site reachable at all") coverage, point any uptime
service at `https://<name>.ocete.ch/health` — the same endpoint the monitor
uses.

## Fleet backups

Install once per host (and re-run after changing backup settings in
group_vars):

```bash
ansible-playbook playbooks/install-backup.yml
```

Every night (systemd timer `octbase-fleet-backup.timer`, 04:00) the root-level
`backup-fleet.sh` iterates the same client registry the monitor uses and, per
client: dumps the database (`pg_dump -Fc`), **restore-tests the dump** into a
throwaway Postgres (same pinned major, `backup_test_image` — a backup that
never restored is a hope, not a backup), archives attachments + `.env`, and
prunes files older than `backup_retention_days`. Root is not a convenience
here: rootless podman is per-user, so no single account can see all client
containers. Results: `{{ fleet_backup_root }}/<client>/` + `backup.log`;
failures exit non-zero so systemd surfaces them.

Off-host copies: set `backup_offhost_cmd` in `inventory/group_vars/all/main.yml`
(e.g. an `rclone sync` to versioned, client-side-encrypted object storage)
and re-run the install playbook — the command runs after every backup and its
failure fails the unit. Until it is set, backups stay on the host they
protect (readiness plan B1 stays open).

The legacy `backup/backup-octbase.sh` (claude account, 03:30 timer) keeps
covering the resident dev/demo stacks — it cannot see client accounts'
containers, which is exactly why the fleet job exists.

## Production settings — the compose override

The app repo's `podman-compose.yml` is tuned for dev: it hardcodes
`OCTBASE_DEMO_MODE: "true"`, a localhost CORS origin, and does not pass
`OCTBASE_EDITION` / `OCTBASE_OPTION_JIRA_IMPORT` / `OCTBASE_MAX_USERS` /
`OCTBASE_SECURE_COOKIES` into the API container. Client stacks therefore
always run with the layered override this repo ships:

```
podman-compose -f podman-compose.yml -f podman-compose.client.yml up -d
```

`playbooks/files/podman-compose.client.yml` turns demo mode **off**, sets the
real CORS origin/secure cookies, passes the edition/add-on/seat variables from
`.env`, and bind-mounts `~/octbase/attachments` as a **persistent attachments
volume** (the base compose keeps uploads in the container filesystem, where
they would be lost on recreate). The systemd user unit always starts the stack
with both files.

## Security notes

- Demo mode off, `OCTBASE_SECURE_COOKIES=true`, unique ≥32-byte JWT/SCM/MFA
  secrets per client, generated at first deploy, stored only in the client's
  `.env` (0600, owned by the client account).
- Postgres/API/frontend ports bind to `127.0.0.1` — only the edge proxy
  (which terminates TLS) is public. `OCTBASE_TRUSTED_PROXIES` is set per
  stack (default `10.89.0.0/16`, the rootless-podman network range; verify
  with `podman network inspect octbase_default` inside a client account).
- Blast radius per client = one Linux account: distinct user namespaces,
  distinct DBs, per-service resource limits from the base compose file.

### Secrets & the SMTP vault

This repo carries exactly one secret: the platform's SMTP relay password.
Everything else per client (DB password, JWT/SCM/MFA secrets) is generated at
first deploy and never leaves the client's `.env` on the server.

That password lives in `inventory/group_vars/all/vault.yml`, encrypted with
Ansible Vault, as `vault_smtp_pass`; `main.yml` only references it
(`smtp_pass: "{{ vault_smtp_pass | default('') }}"`). The encrypted file **is**
committed — the ciphertext is the point. The vault password is not in this
repo. `inventory/group_vars/all/vault.yml.sample` documents the file.

```bash
ansible-vault create inventory/group_vars/all/vault.yml   # first time
ansible-vault edit   inventory/group_vars/all/vault.yml   # rotate
ansible-vault view   inventory/group_vars/all/vault.yml   # read-only check
```

Every playbook run then needs the vault password — either `--ask-vault-pass`,
or `export ANSIBLE_VAULT_PASSWORD_FILE=~/.octbase-vault-pass` (mode 0600, kept
**outside** the repo) to skip the prompt:

```bash
ansible-playbook playbooks/create-instance.yml -e client=acme --ask-vault-pass
```

Absent `vault.yml`, `smtp_pass` falls back to empty — the relay is then
unauthenticated (with `smtp_host` empty the API just logs mail to stdout), so
a missing vault degrades mail rather than breaking a deploy. After rotating
the password, re-run `create-instance.yml` for **every** active client: the
`.env` files are only updated on a playbook run.

## Platform documentation

This README covers the per-client toolkit only. For the picture across all
four repositories — what runs on the host, how a change travels from the dev
checkout via the demo to client instances, and where each concern's
authoritative documentation lives — see
[`docs/platform-overview.md`](docs/platform-overview.md). Before changing env
variables, ports, editions, versions, or health probing anywhere in the
platform, consult [`docs/consistency-register.md`](docs/consistency-register.md):
the cross-repo contracts are conventions, not CI-enforced, and that register
tracks them (and the currently known drift) explicitly.

## Security & data protection

See [`docs/security-data-protection-concept.md`](docs/security-data-protection-concept.md)
for the platform's security and data-protection concept: the implemented
technical measures mapped to the RiLi-Webservices and the Kanton Zürich
"Sichere Website" guidance, the backup/restore and MFA-enforcement concepts,
and the open organizational items (AV contracts, VVT, pentest, edge
restriction).

## Known gaps / next steps

The prioritized, acceptance-criteria'd version of this list — including what
must land **before the first paying client** — is
[`docs/production-readiness-plan.md`](docs/production-readiness-plan.md).

- **Off-host backups**: the per-client nightly backup (DB + restore test +
  attachments + `.env`) is implemented (`install-backup.yml`), but
  `backup_offhost_cmd` is not configured yet — until an encrypted, versioned
  off-host destination is set, backups die with the disk they protect
  (readiness plan B1).
- **Filesystem quotas**: `disk_quota_gb` is enforced only where the
  filesystem has `usrquota` enabled; on the current host it is monitor-only.
  Decide per host whether to enable `usrquota` on `/home`
  (fleet-concept §3).
- **Image builds**: each client account builds its own images from the synced
  source (~identical work per client). At ~10+ clients, build once and
  distribute via a registry or `podman save|load` — the app repo's CI already
  publishes per-commit images to GHCR on every `main` push, which is the
  natural starting point.
