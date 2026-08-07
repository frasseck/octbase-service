# octbase-service

Operations toolkit for running **one Octbase stack per client** across the
octbase.io production host(s). It implements the stack-per-tenant model
recommended in the app repo's `docs/hosting-concept.md` (§5 Model A / §16 O1);
the multi-host model is [`docs/fleet-concept.md`](docs/fleet-concept.md):

- every client gets a **dedicated Linux account** `oct-<name>` running its own
  rootless-podman stack (Postgres + API + frontend + mobile), capped by a
  **systemd user-slice** (memory/CPU/tasks) and a **disk quota** — both
  ledger-managed, changeable at any time (`set-resources.yml`),
- each instance is **pinned to one inventory host** (`host:` in its ledger
  entry); every per-client playbook scopes itself to that host, and
  `migrate-host.yml` moves an instance between hosts,
- a **subdomain** `<name>.octbase.io` is routed by that host's edge reverse
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
   DNS: <name>.octbase.io ──▶ edge reverse proxy (Caddy, root-managed)
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

## The fleet: prod01 and dev01

Two servers, both ordinary members of `octbase_hosts` in
`inventory/hosts.yml`:

|  | `prod01` | `dev01` |
|---|---|---|
| Role | Pure fleet server — client stacks and nothing else | Fleet server **plus** the `claude` development account |
| Ledger clients | New clients land here by default (`default_client_host`) | `beyags`, `demo` |
| Provisioned by | `setup-host.yml` | `setup-host.yml` + `setup-ops-host.yml` |

`dev01` is not a second class of machine and not a disposable one: it runs
real ledger clients, so `install-monitoring.yml` and `install-backup.yml`
must sweep it exactly as they sweep `prod01`. The only thing that
distinguishes it is one extra account, and the workstation toolchain that
account exists for (see [The development host](#the-development-host-dev01)).
Placement is the ledger's `host:` field; `default_client_host` is `prod01`,
so putting a client on `dev01` is an explicit choice.

## Repository layout

| Path | Purpose |
|---|---|
| `ledger/clients/*.yml` | **The client ledger** — one file per client, committed to git |
| `ledger/ledger.py` | Ledger CLI: `new`, `list`, `validate`, `next-ports` |
| `scripts/check-version-drift.py` | Read-only: every version stamp vs the app repo's tags + changelog (C4/C13) |
| `inventory/hosts.yml` | The production host(s) Ansible connects to |
| `inventory/hosts.yml.template` | Pristine reference copy of the above — `diff` a mangled inventory against it, or copy it back to start over |
| `playbooks/tasks/assert-client-host.yml` | Shared pre-flight for every per-client play: the target host must be in the inventory, and the run names the machine it will touch |
| `playbooks/tasks/assert-apparmor-capable.yml` | Shared pre-flight for the three plays that install the compose override: with `client_apparmor` on, the client's runtime must actually be able to apply a profile |
| `playbooks/setup-host.yml` | Provision a **new fleet host** from a stock Ubuntu server (packages, SSH, firewall, edge Caddy) |
| `playbooks/setup-ops-host.yml` | Delta on that baseline for the development host: linger + rootless-podman checks for the `claude` account |
| `scripts/setup-octbase-web.sh` | Stand the public `octbase.io` marketing site up on a fleet host (run as root on the host) |
| `playbooks/vars/host-packages.yml` | The reference host's package capture: baseline / workstation extras / base image |
| `inventory/group_vars/all/main.yml` | Platform-wide defaults (domain, SMTP relay, source path, …) |
| `inventory/group_vars/all/vault.yml` | Ansible Vault: the SMTP relay password (`vault.yml.sample` documents it) |
| `playbooks/create-instance.yml` | Create **or update** a client instance from its ledger entry |
| `playbooks/reconfigure-instance.yml` | Re-run the setup for an existing client, asking for each setting first (quota checked against real usage) |
| `playbooks/sync-instance.yml` | Sync an existing instance's code to an app-repo branch (default `main`), rebuild + restart |
| `playbooks/remove-instance.yml` | Back up and remove a client instance (needs `confirm=`) |
| `playbooks/migrate-instance.yml` | Move an existing installation to its own client account and/or a new domain (same host) |
| `playbooks/migrate-host.yml` | Move a client instance to **another host** (staged via the admin machine) |
| `playbooks/suspend-instance.yml` | Stop a `status: suspended` client non-destructively; domain answers 503 |
| `playbooks/reset-user-password.yml` | Reset one Octbase **user's** password directly in a client's database (no mail needed) |
| `playbooks/set-max-users.yml` | Set `OCTBASE_MAX_USERS` for a client and restart its stack |
| `playbooks/set-resources.yml` | Apply a client's memory/CPU/tasks caps + disk quota, no redeploy |
| `playbooks/set-version.yml` | Deploy a client's `app_version` release tag, stamp it and verify via `/api/v1/version` |
| `playbooks/install-monitoring.yml` | Install the fleet monitor (script + systemd timer) on every host |
| `playbooks/install-backup.yml` | Install the nightly fleet backup (script + systemd timer) on every host |
| `playbooks/templates/` | `.env`, systemd user unit + slice drop-in, edge Caddy vhost templates |
| `playbooks/templates/podman-compose.client.yml.j2` | Production compose override (see below) |
| `playbooks/install-apparmor.yml` | Carry the AppArmor policy to hosts that already exist, without re-running the baseline |
| `playbooks/tasks/apparmor.yml` | The policy deployment itself — shared by `setup-host.yml` and `install-apparmor.yml` |
| `playbooks/templates/apparmor/` | One AppArmor profile per platform component and per container ([below](#apparmor-profiles)) |
| `playbooks/vars/apparmor-profiles.yml` | Which profiles ship, what each attaches to, and the mode it loads in |
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
- The `bcrypt` Python module (`apt install python3-bcrypt`), to hash a client's
  initial admin password. Needed on a **first** deploy only; `create-instance.yml`
  fails with that instruction if it is missing.
- SSH access to the app repo (`frasseck/octbase-app.git`): `create-instance.yml`
  clones the release tag a client's `app_version` names into a cache on this
  machine (`octbase_release_cache`). The production host never talks to GitHub.
- A checkout of the app repo at `octbase_src` — no longer the client deploy
  source, only where `install-monitoring.yml` reads `check-health.sh` from.
- SSH access to the production host as an **unprivileged account that can
  sudo** — root login is refused there (`PermitRootLogin no`, set by
  `setup-host.yml`), and every play elevates with `become: true`. The account
  comes from your `~/.ssh/config` or from `-e ansible_user=<account>`;
  `inventory/hosts.yml` pins none on purpose. Add `--ask-become-pass` unless
  that account's sudo is passwordless.

**Production host:** `podman`, `podman-compose`, `loginctl` (systemd),
`rsync`, `curl`. The edge reverse proxy (Caddy) is managed outside this repo;
this tooling only *generates* per-client vhost snippets for it.

## The ledger

One YAML file per client in `ledger/clients/`. The file name is the client
`name`, which is also the subdomain label and the Linux account suffix.
See `ledger/clients/example.yml.sample` for the full field reference:

```yaml
name: acme                 # → acme.octbase.io, Linux user oct-acme
display_name: ACME GmbH
contact: it@acme.example   # also the login of the first SUPER_ADMIN (see below)
edition: business          # team | business | enterprise
jira_import: true          # add-on, booked by default on every edition (see C3)
max_users: 25              # → OCTBASE_MAX_USERS
registered: 2026-07-10
status: active             # active | suspended | removed
app_version: "1.0.1"       # deploys app repo tag v1.0.1 AND stamps it
host: prod01               # inventory host the instance runs on
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
    --max-users 25 --contact it@acme.example   # scaffolds the file, allocates ports
./ledger/ledger.py set acme --edition enterprise --max-users 50  # change fields in place
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
./ledger/ledger.py new acme --display "ACME GmbH" --edition business \
    --max-users 25 --contact it@acme.example
./ledger/ledger.py validate
git add ledger/clients/acme.yml && git commit -m "ledger: onboard acme"

ansible-playbook playbooks/create-instance.yml -e client=acme
```

Or let the playbook ask. Run it for a client that has **no** ledger entry and
its first play interviews you — display name, contact, edition, add-on, seats,
host, disk quota, app version — then calls the same `ledger.py new` with your
answers and validates the whole ledger before provisioning anything:

```bash
ansible-playbook playbooks/create-instance.yml -e client=acme
```

The host question offers the names in `inventory/hosts.yml`; an empty answer
takes `default_client_host`. Either way the entry is written but **not
committed** — the git history of `ledger/clients/` is the audit trail of the
client base, so commit it yourself. The dialog needs a terminal and is refused
under `--check`; a scripted onboarding uses the two-command form above.

The playbook then prints the two **manual** steps:
1. **DNS**: create `acme.octbase.io` → A/AAAA record for the production host.
2. **Edge proxy**: the playbook wrote `/etc/octbase/edge/acme.caddy`
   (`acme.octbase.io { reverse_proxy 127.0.0.1:8110 }`). Include it from the
   edge Caddyfile (`import /etc/octbase/edge/*.caddy` once, then just reload).

Verify: `curl -s https://acme.octbase.io/health` → `{"status":"ok",…}`.

On the **first** deploy only, the playbook also provisions the instance's
initial administrator, and prints the credentials as its last output:

```
Initial SUPER_ADMIN for acme.octbase.io — shown once, not recoverable:
  login:    it@acme.example
  password: <24 random characters>
```

**The login is the ledger's `contact`.** That address has to be a real mailbox
the client can read: it is the only account on a fresh instance, and the app's
self-service password reset is the only way back into it. (It used to be
`admin@acme.octbase.io` — an address on the client's own subdomain, with no
mailbox and no MX record behind it, so the recovery path went nowhere.) A
missing or malformed `contact` fails `ledger.py validate` for any `active`
client, and the playbook refuses before it builds anything.

Only a **first** deploy consumes it. Editing `contact` afterwards changes the
billing/ops contact and nothing else — an instance keeps the admin login it was
created with. To change that login later, rename the user in the app.

It generates the password on the admin machine, writes only its **bcrypt hash**
into the client's `.env` (`OCTBASE_BOOTSTRAP_ADMIN_EMAIL` /
`OCTBASE_BOOTSTRAP_ADMIN_PASSWORD_HASH`), and the app creates the `SUPER_ADMIN`
from those at its first start, while the users table is still empty. The
plaintext is never written anywhere — not to the repo, the ledger, or the
`.env` — so that printout is genuinely the only copy. Hand it over on a secure
channel (not email) and have the client change it after first login.

Without this the instance would have no way in at all: the app has no public
signup and no first-run flow, its user API refuses to assign `SUPER_ADMIN`, and
an invited user always lands as `USER`.

Re-runs are inert: `.env` already exists, so it is not rewritten, no password is
generated or printed, and the app ignores the bootstrap keys once the
installation has users (a stale or malformed value there can never keep a
running instance from booting).

**If the password is lost**, the recovery is to replace it, not to re-run the
playbook — the `.env` still holds the *old* hash, so re-bootstrapping would just
restore the password you no longer have. On the client's host, as `oct-<name>`:
hash a new password, put it in `~/octbase/.env` as
`OCTBASE_BOOTSTRAP_ADMIN_PASSWORD_HASH`, delete the admin row
(`podman exec octbase_postgres_1 psql -U octbase -d octbase -c "DELETE FROM users WHERE email = 'it@acme.example'"`
— the address in `OCTBASE_BOOTSTRAP_ADMIN_EMAIL`), then
`systemctl --user restart octbase`.

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

Or let the playbook ask, the same way onboarding does:

```bash
ansible-playbook playbooks/reconfigure-instance.yml -e client=acme
```

It shows every current value, asks for each in turn — **empty keeps it** — and
writes the answers through `ledger.py set`, which edits the file line by line
so its comments and `notes` survive. Then it re-runs the setup above. Answering
everything empty is simply a plain re-run.

Changeable here: `display_name`, `contact`, `edition`, `jira_import`,
`max_users`, `app_version`, `disk_quota_gb`, `monitor_edge_probe` and the
`resources` caps. **Not** changeable, because each has its own playbook and
editing the field alone would only desynchronise the ledger from the fleet:
`name` (→ `migrate-instance.yml`), `host` (→ `migrate-host.yml`), `status`
(→ `suspend-instance.yml` / `remove-instance.yml`), and the allocated `ports`.

Before applying, it measures the account's real disk usage and **warns if the
new quota is below it** — `setquota` takes that number as the *hard* limit, so
it does not shrink anything, it makes the next write fail. On a live stack that
is Postgres unable to extend a table. The run pauses there so you can abort.

For a non-interactive change, `ledger.py set` is the same edit without the
dialog:

```bash
./ledger/ledger.py set acme --edition enterprise --max-users 50
./ledger/ledger.py validate
git add ledger/clients/acme.yml && git commit -m "ledger: acme to enterprise"
ansible-playbook playbooks/create-instance.yml -e client=acme
```

### Which version an instance runs

`create-instance.yml` deploys the app repo **tag** that the ledger's
`app_version` names — `app_version: "1.0.8"` deploys tag `v1.0.8` — and stamps
`OCTBASE_APP_VERSION` with the same value. The version therefore *selects* the
code rather than just labelling it, so a client cannot run code that disagrees
with its own stamp (C4), and nothing about the admin machine's checkout can
reach a client. `octbase_version` in `group_vars` is the default for ledger
entries that set no `app_version`.

To move a client to a new release: tag it in the app repo (with a dated
`CHANGELOG.md` entry), set `app_version` in the client's ledger file, commit,
and re-run `create-instance.yml`. It refuses up front if the tag does not
exist, naming the tag it wanted.

To see where every stamp stands — the fleet default plus each client — run:

```bash
scripts/check-version-drift.py     # read-only; contacts no client host
```

It prints each stamp's distance from the newest app repo tag and checks the
tag and dated changelog entry exist. **Trailing the newest release is a `WARN`,
not an error** (exit status stays 0): pinning behind is a deliberate choice,
and the bump is the rollout decision itself. `FAIL` means a stamp names a
version that has no tag, is ahead of every tag, or has no changelog entry.

### Sync an instance to a branch (main)

To run an instance's code straight from a **branch** instead of a release tag —
the way the demo was fed by `git pull` before it became a managed client — use
`sync-instance.yml`. This is the unreleased-code path: use it for the demo and
for testing, not to put a client on a release.

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
never touches secrets, data, ports, or ledger-managed settings. The one `.env`
line it writes is the `OCTBASE_APP_VERSION` stamp, re-applied from the ledger
(`app_version`, else `octbase_version`) so a sync can't leave the stamp behind
the code — to change it, edit the ledger entry *before* syncing. To re-apply
the other ledger/platform `.env` settings, run `create-instance.yml`. Make sure
the branch is at or above the running schema version before syncing a live
instance.

### Reset a user's password

Client stacks have no Mailpit, so the self-service reset mails a token to a real
mailbox. When that is not available — a locked-out admin, a departed contact —
reset the password in the database instead:

```bash
ansible-playbook playbooks/reset-user-password.yml -e client=acme \
    -e email=someone@acme.ch
```

A 24-character password is generated and printed **once** at the end of the run;
it is never written to disk. To set a known one instead (it must still clear the
app's 12-character minimum and the common-password blocklist):

```bash
ansible-playbook playbooks/reset-user-password.yml -e client=acme \
    -e email=someone@acme.ch -e user_password='…'
```

The playbook writes the same end state as the app's own reset
(`auth/password_reset.go`), in one transaction: the new bcrypt hash (cost 12, on
the admin machine — `python3-bcrypt` required), every refresh token deleted so
existing sessions end, any pending reset link marked spent, and one
`USER_PASSWORD_RESET` audit row with `method: ops_playbook` so an out-of-band
reset is as visible in `/audit-logs` as a self-service one. It then reads the
row back and fails if the stored hash or the session count is not what it
expects. No restart, no downtime — the API reads `users` on every login.

The run stops rather than guessing if the address does not match exactly one
account. It deliberately does **not** touch:

> **MFA** — a new password will not help someone who lost their authenticator;
> `mfa_credentials`/`mfa_recovery_codes` are a separate decision. The result
> message flags it when the account has MFA on.
> **Deactivated accounts** — the password will be valid but login still refused;
> the run warns instead of reactivating, since that is a licensing decision.
> **`POSTGRES_PASSWORD`** — the Postgres *role* password is instance
> infrastructure, lives in `.env`, and rotating it means recreating the stack.

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

### Set the Octbase version

The version is ledger-managed like the seat count (edit `app_version`, commit,
run). It is not just a stamp: the value selects the app repo tag `v<version>`
that gets deployed, so code and stamp cannot drift apart (C4).

```bash
ansible-playbook playbooks/set-version.yml -e client=acme
```

For an ad-hoc override (extra-vars beat the ledger), pass it explicitly —
and update the ledger afterwards so it stays the source of truth:

```bash
ansible-playbook playbooks/set-version.yml -e client=acme -e app_version=1.0.8
```

The playbook refuses before touching the instance if the app repo has no
`v<version>` tag, then deploys that tag, stamps `OCTBASE_APP_VERSION`,
rebuilds the images, restarts, waits for `/health`, and finally reads
`/api/v1/version` back — failing if the running instance reports anything
other than the requested version.

> Versions move forward in practice. A downgrade re-deploys older code against
> a database the newer code may already have migrated; check the schema
> version before pointing a live instance at a lower version. Use
> `create-instance.yml` (idempotent) instead when you also want the other
> ledger- and platform-managed `.env` settings re-applied.

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

### Add a host to the fleet

A stock Ubuntu 24.04+ server becomes a fleet host in two steps:

```bash
# 1) add the server to inventory/hosts.yml (name + ansible_host), then:
ansible-playbook playbooks/setup-host.yml -e target_host=prod2
ansible-playbook playbooks/install-monitoring.yml
ansible-playbook playbooks/install-backup.yml
```

`setup-host.yml` asks three questions before it starts: **which account to
connect as** (must already exist on the server and be able to sudo — on a
stock cloud image that is `ubuntu`), **which admin accounts to create**,
space-separated, and **what to name the node** (empty keeps its current name).
Answer any of them on the command line to skip that prompt, which is what a
non-interactive run needs:

```bash
ansible-playbook playbooks/setup-host.yml -e target_host=prod2 \
    -e setup_user=ubuntu -e admin_users='lfrasseck claude' \
    -e host_fqdn=prod2.octbase.io
```

**Naming the node** writes the short label to `/etc/hostname` and maps
`127.0.1.1` to the FQDN plus that label in `/etc/hosts` — both, because sudo
prints `unable to resolve host …` on every invocation otherwise. It also drops
`preserve_hostname: true` into `/etc/cloud/cloud.cfg.d/`, without which
cloud-init re-applies the provider's metadata hostname at the next boot and
silently undoes the rename. This is the node's own identity only; it has no
bearing on which client domains the host serves, which come from the ledger
and the edge snippets.

**Logging in afterwards:** SSH moves to port 1012 and accepts keys only, so
`ssh -p 1012 <account>@<host>` where `<account>` is any account you named —
or the setup account, which is always allowed so a run cannot lock itself out.
Each named account is created if missing (sudo group, locked password,
passwordless sudo via `/etc/sudoers.d/90-octbase-admins`) and authorized with
**the setup account's own `authorized_keys`** — necessarily a key that works,
since it is the one the run connected with. So the key that provisioned the
host opens every admin account on it: they are separate identities for audit,
not separate credentials. Give an operator their own by replacing that
account's `authorized_keys` afterwards — the playbook adds keys without
removing them, so a hand-added key survives later runs.

If the setup account has no `authorized_keys` (you connected by password),
the run fails rather than creating accounts nobody can log into. The
allow-list is rewritten on every run, so a bootstrap account like `ubuntu`
drops out as soon as a run connects as something else.

You add the host's name and `ansible_host` to `inventory/hosts.yml`; the run
adds the rest. On success it records that host's `ansible_user` and
`ansible_port: 1012` into its entry, between markers naming the host — so the
port move does not have to be remembered, and every later playbook reaches the
server without extra flags. **Commit that change**, and don't hand-edit inside
the markers: the next run rewrites them. Change the answer instead
(`-e setup_user=…`) and re-run.

`setup-host.yml` installs the baseline package set (rootless podman and its
prerequisites, Caddy, fail2ban, quota tooling, diagnosis tools — see
`playbooks/vars/host-packages.yml`), sets timezone and locale, hardens sshd,
enables the firewall, configures per-account disk quotas in `fstab`, creates
`/etc/octbase/{edge,clients.d}`, lays down the edge Caddyfile with the
`import /etc/octbase/edge/*.caddy` line client vhosts rely on, and loads the
[AppArmor profiles](#apparmor-profiles) for the platform's components. It is
idempotent, so it also serves as "bring a hand-built host up to the current
baseline" — including `prod01` and `dev01`.

Naming the target is mandatory (`-e target_host=`): the play restarts SSH and
enables the firewall, and an unscoped run would do that to every host at once.

Two things to know before the first run:

- **SSH moves to port 1012.** The run's own connection survives, but the next
  one needs the new port — add `ansible_port: 1012` to the host's inventory
  entry (or your `~/.ssh/config`). `ssh_allow_users` must contain the account
  you connect as; the play asserts this rather than locking you out.
- **Disk quotas need one reboot.** The playbook writes `usrquota` into
  `fstab`; the quota package's boot-time `quotacheck` is what makes the
  numbers true, so enforcement starts after a restart. Until then
  `create-instance.yml` warns that usage is monitored but not enforced —
  which is the state both hosts are in today.
- **AppArmor policy lands with the baseline.** The run loads nine profiles and
  restarts the edge proxy once (a sub-second blip, and only when the drop-in
  that confines it actually changed). Two of them enforce from that moment:
  the fleet monitor's and the fleet backup's — both of which are installed
  *afterwards* by their own playbooks, which is fine, a profile simply applies
  from the first exec of the file it names. On a host that is already in
  service, carry the policy over with `install-apparmor.yml` instead of
  re-running this playbook — see [AppArmor profiles](#apparmor-profiles).

Then place clients on it via `host: prod2` in their ledger entries.

Not covered, deliberately: DNS, Ubuntu Pro attachment, and the off-host
backup sync (`backup_offhost_cmd`).

#### The development host (dev01)

`dev01` carries the `claude` development account on top of the baseline.
That is a **delta playbook, not a second baseline** — the same pattern as
`install-monitoring.yml` / `install-backup.yml`: one baseline, one place to
change it. The baseline first, the delta second:

```bash
ansible-playbook playbooks/setup-host.yml -e target_host=dev01 \
    -e setup_user=<account> -e admin_users='lfrasseck claude' \
    -e install_workstation_extras=true -e host_fqdn=dev01.octbase.io
ansible-playbook playbooks/setup-ops-host.yml -e target_host=dev01
```

The **baseline owns the account**: `claude` is passed in `admin_users`, which
gives it its uid, home, shell, sudo drop-in, SSH key and `AllowUsers` entry —
and the baseline rebuilds that allow-list from `admin_users` on *every* run,
so an account created anywhere else would lose its SSH access the next time
the baseline ran, silently. The delta therefore **asserts** the account
exists and adds only what the baseline has no reason to know about: linger,
and a check that a subordinate id range exists for rootless podman. It
refuses to pick id ranges itself — overlapping ranges give two accounts the
same namespace ids, so when the entry is missing it stops and prints the
`usermod` command instead.

`install_workstation_extras=true` is what installs the browser, Go, Node and
`gh` toolchain the development account exists for; on `prod01` it stays off,
which is the other visible difference between the two machines.

Deliberately **not** done by either playbook: no repository is checked out on
the target (the servers never talk to GitHub — deploys rsync from the admin
machine), no development stack is brought up, and no client is placed.
Repositories and tooling are a human's first login, by hand; the account's
own `.env` files live in `~/credentials` on the box and never enter this
repo. Clients land on `dev01` like on any host: `host: dev01` in the ledger
entry, then the usual playbooks.

### Move an instance to another host

Placement is the `host:` field in the ledger (see `inventory/hosts.yml` for
valid names; the model is `docs/fleet-concept.md`). Every per-client playbook
runs against `octbase_hosts` and ends the play on every host that is not the
client's, so it prints the target it resolved — client, host, `ansible_host`,
port, account — before it changes anything, and **fails** if the ledger's
`host:` is not a name in the inventory. That check exists because without it
the mismatch ends the play everywhere and the run reports success having
touched nothing (OCT-48). To move client `acme` from `dev01` to `prod01`:

```bash
# 1) edit ledger/clients/acme.yml → host: prod01, validate, commit
# 2) octbase_src must be at the client's release (schema ≥ the source's)
ansible-playbook playbooks/migrate-host.yml \
    -e client=acme -e source_host=dev01 -e confirm=acme
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
  probes the public edge (`https://<name>.octbase.io/health`), and checks
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
service at `https://<name>.octbase.io/health` — the same endpoint the monitor
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

## The marketing site (octbase.io)

The public `octbase.io` + `www.octbase.io` site (repo `frasseck/octbase-web`
— static site + Go contact-form mailer, no dependency on the app) runs on a
fleet host under its own unprivileged `oct-web` account as a rootless-podman
stack on loopback port **8120**. That port is reserved in `ledger/ledger.py`
(`RESERVED_PORTS`) so the client port allocator never hands it out — changing
it means changing both places (contract C8). The site is not a ledger client;
it is stood up by a script, run **as root on the host** after
`setup-host.yml` has laid down the edge Caddyfile:

```bash
sudo bash scripts/setup-octbase-web.sh --src /path/to/octbase-web  # interactive
sudo bash scripts/setup-octbase-web.sh --src ... --yes             # non-interactive
```

The site code is rsynced from a local checkout (`--src`) — the host never
talks to GitHub, so get the checkout there the way the rest of this toolkit
does, by rsync from the admin machine. The script creates the `oct-web`
account (locked password, no SSH), deploys and builds the stack, installs a
systemd user unit that starts it on boot via linger, verifies the site
answers on loopback, and only then writes the edge vhost snippet
(`/etc/octbase/edge/octbase-web.caddy`) — `caddy validate` before reload,
reverted on failure, the main Caddyfile untouched.

Idempotent: a re-run re-syncs, rebuilds and restarts. It never overwrites an
existing `.env` (`~oct-web/credentials/.env.octbase-web`, mode 0600 — the
only copy of the contact-form SMTP secrets); pass `--env-file` to replace it
deliberately. DNS stays manual, and the site must stay password-free — the
script warns when either is not the case.

## Production settings — the compose override

The app repo's `podman-compose.yml` is tuned for dev: it hardcodes
`OCTBASE_DEMO_MODE: "true"`, a localhost CORS origin, and does not pass
`OCTBASE_EDITION` / `OCTBASE_OPTION_JIRA_IMPORT` / `OCTBASE_MAX_USERS` /
`OCTBASE_SECURE_COOKIES` into the API container. Client stacks therefore
always run with the layered override this repo ships:

```
podman-compose -f podman-compose.yml -f podman-compose.client.yml up -d
```

`playbooks/templates/podman-compose.client.yml.j2` turns demo mode **off**, sets the
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
- AppArmor confines the platform's own root-run components on every host, and
  ships policy for every container ([below](#apparmor-profiles)).

### AppArmor profiles

`setup-host.yml` writes nine profiles into `/etc/apparmor.d/` and loads them,
so a fleet host has the policy from the moment it is provisioned and reloads it
at every boot. They come from `playbooks/templates/apparmor/`; what each one is
for is in `playbooks/vars/apparmor-profiles.yml`, and the rules themselves are
commented at length in the profiles.

**On a host that already exists**, use the delta playbook rather than the
baseline:

```bash
ansible-playbook playbooks/install-apparmor.yml                        # whole fleet
ansible-playbook playbooks/install-apparmor.yml -e target_host=prod01  # one host first
ansible-playbook playbooks/install-apparmor.yml --check --diff         # see it first
```

Both entry points run the same `playbooks/tasks/apparmor.yml`, so they cannot
drift. Re-running the baseline works too and is supported — but it is the
*whole* baseline, and on a host serving clients it restarts the SSH socket,
re-enables the firewall and rewrites the sshd allow-list from its
`admin_users` answer; answer that with less than the host currently allows and
the next connection is refused. Bringing one hardening measure to a live host
should not put that on the table.

`install-apparmor.yml` is safe to run repeatedly: a profile is re-loaded only
when its file changed or the kernel does not hold it. The one disruptive
moment is the **first** run on a host, which writes the `caddy.service`
drop-in — and a drop-in only reaches a running daemon on a restart, so Caddy is
restarted once, a sub-second gap on every domain that host serves. Later runs
leave it alone. `--check --diff` shows the drop-in as a change exactly when the
restart would follow.

It is also how a profile's mode is changed, since the mode is baked into the
file the parser loads:

```bash
ansible-playbook playbooks/install-apparmor.yml -e apparmor_mode_edge=enforce
ansible-playbook playbooks/install-apparmor.yml -e apparmor_mode_platform=complain
```

**Confining something today** — the platform's own root-run components:

| Profile | Confines | Attached by | Mode |
|---|---|---|---|
| `octbase-monitor` | `monitor-all.sh` — root, every 5 min, across every client | executable path | `apparmor_mode_platform` (enforce) |
| `octbase-backup` | `backup-fleet.sh` — root, nightly, every client's dumps and `.env` | executable path | `apparmor_mode_platform` (enforce) |
| `octbase-edge-caddy` | the public edge proxy | `caddy.service` drop-in | `apparmor_mode_edge` (complain) |

The edge is confined through a unit drop-in rather than a path attachment on
`/usr/bin/caddy`, because AppArmor resolves an executable's path against the
container's own root — a path attachment would also catch the Caddy running
*inside* the frontend, mobile and marketing containers. It starts in **complain**
mode deliberately: its failure mode is every client domain at once. Read what it
would have blocked, then promote it:

```bash
journalctl -k | grep 'apparmor=' | grep octbase-edge-caddy   # ALLOWED = would have denied
# add anything genuine to /etc/apparmor.d/local/octbase-edge-caddy, then:
ansible-playbook playbooks/install-apparmor.yml -e apparmor_mode_edge=enforce
```

Every profile ends with `include if exists <local/<name>>`, so site-specific
additions (a different MTA, the off-host sync helper `backup_offhost_cmd`
names) go in `/etc/apparmor.d/local/` and survive the next run — the shipped
files are rewritten each time.

**Confining nothing yet** — the six container profiles (`octbase-postgres`,
`-api`, `-frontend`, `-mobile`, `-web`, `-web-mailer`). **Rootless podman
cannot apply an AppArmor profile at all:**

```
$ podman info  →  "apparmorEnabled": false, "rootless": true   (the host has AppArmor)
$ podman run --security-opt apparmor=<any> …
Error: apparmor profile "<any>" specified, but Apparmor is not enabled on this system
```

Rootless podman re-execs into a user namespace where securityfs is not mounted,
so it reports AppArmor unavailable and rejects any profile — and
`containers/common` refuses profiles in rootless mode in any case, since loading
one needs root. Client stacks are rootless by design, so these profiles are
loaded, reviewable and worn by nothing. `client_apparmor: true` in
`inventory/group_vars/all/main.yml` wires them into the compose override; before
it does anything, `create-instance.yml` asks the client's own podman and
**refuses the run** — the failure without that check is not an unconfined stack
but one that does not start, because podman fails the container rather than
ignoring the option.

Adding a service to either compose file means adding a profile for it
(contract C18).

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
- **Monitor alerting is armed but not firing**: `install-monitoring.yml` now
  installs an MTA, templates the relay and refuses to install a monitor that
  cannot alert (register D28), and `alert_email` is set. It stays inert until
  `inventory/group_vars/all/vault.yml` supplies `vault_smtp_pass` (OCT-23) —
  until then the playbook fails its pre-flight rather than installing something
  that looks armed. State changes always reach the journal regardless; what is
  missing is the push.
- **Filesystem quotas**: `disk_quota_gb` is enforced only where the
  filesystem has `usrquota` enabled; on the current host it is monitor-only.
  Decide per host whether to enable `usrquota` on `/home`
  (fleet-concept §3).
- **Container AppArmor confinement is written but inert**: a profile exists and
  is loaded for all six containers the platform runs, and nothing wears one —
  rootless podman rejects AppArmor profiles outright, and rootless is the
  tenancy model. The host-side profiles (monitor, backup, edge) *do* enforce.
  See [AppArmor profiles](#apparmor-profiles) and register §2.19.
- **Image builds**: each client account builds its own images from the synced
  source (~identical work per client). At ~10+ clients, build once and
  distribute via a registry or `podman save|load` — the app repo's CI already
  publishes per-commit images to GHCR on every `main` push, which is the
  natural starting point.
