# octbase-service

Operations toolkit for running **one Octbase stack per client** on the ocete.ch
production host. It implements the stack-per-tenant model recommended in the
app repo's `docs/hosting-concept.md` (§5 Model A / §16 O1):

- every client gets a **dedicated Linux account** `oct-<name>` running its own
  rootless-podman stack (Postgres + API + frontend + mobile),
- a **subdomain** `<name>.ocete.ch` is routed by the host's edge reverse proxy
  to that client's frontend port (DNS entries are created manually),
- a **git-versioned ledger** (`ledger/clients/*.yml`) is the single source of
  truth for who the clients are, which edition they booked, add-ons, seats,
  registration date — and it directly drives the Ansible playbooks,
- **monitoring** aggregates the app repo's `check-health.sh` across all client
  stacks every 5 minutes and alerts on state changes,
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
| `inventory/group_vars/all.yml` | Platform-wide defaults (domain, SMTP relay, source path, …) |
| `playbooks/create-instance.yml` | Create **or update** a client instance from its ledger entry |
| `playbooks/remove-instance.yml` | Back up and remove a client instance (needs `confirm=`) |
| `playbooks/set-max-users.yml` | Set `OCTBASE_MAX_USERS` for a client and restart its stack |
| `playbooks/install-monitoring.yml` | Install the fleet monitor (script + systemd timer) on the host |
| `playbooks/templates/` | `.env`, systemd user unit, edge Caddy vhost templates |
| `playbooks/files/podman-compose.client.yml` | Production compose override (see below) |
| `monitoring/monitor-all.sh` | Root-level aggregator that probes every client stack |
| `monitoring/octbase-monitor.{service,timer}` | systemd units for the 5-minute monitor run |
| `backup/backup-octbase.sh` | Daily DB backup with an automated restore test |
| `backup/octbase-backup.{service,timer}` | systemd user units for the nightly backup run |
| `docs/security-data-protection-concept.md` | Security & data-protection concept (standards mapping, open items) |

## Prerequisites

**Admin machine** (where you run the playbooks):
- Ansible ≥ 2.14 (with the bundled `ansible.posix` collection), `rsync`,
  `openssl`, Python 3 with PyYAML (Ansible brings it).
- A checkout of the app repo (`frasseck/octbase.git`) at the release you want
  to ship. Its path is `octbase_src` in `inventory/group_vars/all.yml`.
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
ports:                     # unique per client, allocated by ledger.py
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
secrets or data. Platform-wide values from `inventory/group_vars/all.yml`
(SMTP relay, trusted proxies, retention days) are re-synced into the client's
`.env` on the same run — so after changing one of those, re-run the playbook
for **every** active client:

```bash
ansible-playbook playbooks/create-instance.yml -e client=acme
```

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

## Monitoring

Install once (and re-run after changing monitor settings in group_vars):

```bash
ansible-playbook playbooks/install-monitoring.yml
```

What it does on the host:
- installs the app repo's `octbase-operations/check-health.sh` (two-layer
  container + application probe, JSON output) to `/usr/local/lib/octbase/`,
- installs `monitor-all.sh`, which every 5 minutes (systemd timer
  `octbase-monitor.timer`) iterates all registered clients
  (`/etc/octbase/clients.d/*.conf`, maintained by the playbooks), runs
  `check-health.sh` inside each client's rootless-podman context, and
  additionally probes the public edge (`https://<name>.ocete.ch/health`),
- writes the fleet state to `/var/lib/octbase-monitor/status.json`
  (machine-readable, one object per client: `OK | DEGRADED | DOWN`),
- on any **state change** sends a mail via the local `sendmail` to
  `alert_email` (set it in `inventory/group_vars/all.yml`) and always logs to
  the journal: `journalctl -u octbase-monitor.service`.

Ad-hoc fleet status: `sudo /usr/local/lib/octbase/monitor-all.sh --print`.

The public-edge probe can be disabled per client while its DNS/edge setup is
still pending: set `monitor_edge_probe: false` in the client's ledger file and
re-run `create-instance.yml` (remove the field and re-run once the client is
live). The global default is `edge_probe` in `inventory/group_vars/all.yml`.

For external ("is the site reachable at all") coverage, point any uptime
service at `https://<name>.ocete.ch/health` — the same endpoint the monitor
uses.

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

## Security & data protection

See [`docs/security-data-protection-concept.md`](docs/security-data-protection-concept.md)
for the platform's security and data-protection concept: the implemented
technical measures mapped to the RiLi-Webservices and the Kanton Zürich
"Sichere Website" guidance, the backup/restore and MFA-enforcement concepts,
and the open organizational items (AV contracts, VVT, pentest, edge
restriction).

## Known gaps / next steps

- **Backups**: host-level DB backups with an automated restore test now run
  nightly (`backup/`, systemd timer `octbase-backup.timer` at 03:30; dumps in
  `/home/claude/backups`). Still open: fold this into the per-client model
  (attachments rsync + an off-host/immutable copy, hosting-concept §9.5) and
  wire it into the Ansible playbooks per tenant.
- **Image builds**: each client account builds its own images from the synced
  source (~identical work per client). At ~10+ clients, build once and
  distribute via a registry or `podman save|load`.
- **Suspend**: `status: suspended` is tracked in the ledger and blocks
  `create-instance.yml`, but there is no playbook yet that stops a running
  stack without removing it (`systemctl --user stop octbase` manually).
