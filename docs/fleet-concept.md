# Fleet concept — many instances, many servers

**Status: implemented 2026-07-12** (this document was written first as the
review + implementation spec, then executed; it stays as the authoritative
concept for multi-instance / multi-host operation). The README owns the
per-runbook details; this document owns the *model*.

## 1. The model

One product (Octbase), N client instances, M hosts — managed from one admin
machine, with one git-versioned ledger as the single source of truth:

```
                     admin machine (ansible, ledger, app checkout)
                          │  SSH (per-host, no host↔host trust)
        ┌─────────────────┼──────────────────┐
        ▼                 ▼                  ▼
   host "prod"        host "prod2"       host "…"          (inventory/hosts.yml)
   edge Caddy         edge Caddy                            root-managed, imports
   /etc/octbase/…     /etc/octbase/…                        /etc/octbase/edge/*.caddy
   oct-acme  oct-demo oct-beta …                            one Linux account per
   (rootless podman,  (rootless podman,                     instance, loopback ports
    user slice caps)   user slice caps)
```

Every instance is pinned to exactly one host by its ledger entry
(`host: prod`). Every per-client playbook scopes itself to that host and is a
no-op everywhere else, so a fleet-wide rollout is still just "run the
playbook per active client" regardless of where each client lives.

- **Placement** — `host:` in `ledger/clients/<name>.yml`, validated by
  `ledger.py validate` against `inventory/hosts.yml`. Default:
  `default_client_host` (group_vars).
- **Ports** — allocated globally unique across the whole fleet (not just per
  host) so an instance can move between hosts without renumbering.
- **DNS** — `<name>.ocete.ch` must point at the instance's host; DNS stays a
  manual step and is called out by every playbook that changes placement.
- **Host services** (edge Caddy import line, monitoring, fleet backup) are
  installed once per host: `install-monitoring.yml` and `install-backup.yml`
  run against all inventory hosts.

## 2. Resource governance (give / take)

Resources are governed at the **account level** via the client's systemd user
slice (`user-<uid>.slice`) — one cgroup that caps everything the client runs:
all four containers *and* image builds. Per-service fine-tuning stays in the
app repo's base compose file; the platform knob is the slice.

- Ledger: optional `resources:` block (`memory_max`, `cpu_quota`,
  `tasks_max`); defaults come from `client_default_resources` in group_vars.
- Applied as a drop-in `/etc/systemd/system/user-<uid>.slice.d/99-octbase.conf`
  by `create-instance.yml`, or without a redeploy by
  `set-resources.yml -e client=<name>` (give or take at any time; takes
  effect on daemon-reload, verified via `systemctl show user-<uid>.slice`).

## 3. Disk: quota + per-instance usage monitoring

Two independent layers, so the platform is safe even where the filesystem
cannot enforce quotas:

1. **Enforcement (best effort):** `disk_quota_gb` in the ledger is applied
   with `setquota` (soft = 90%, hard = 100%) when the filesystem holding the
   client home has user quotas enabled; if not, the playbook warns and layer
   2 is the guard. (Enabling `usrquota` on `/home` is a per-host, root
   decision — document it per host when done.)
2. **Monitoring (always):** the fleet monitor measures each client's home
   directory (`du`, cached, refreshed hourly) and writes
   `disk_bytes` / `disk_pct` into `status.json`. At ≥ `DISK_ALERT_PCT`
   (default 90%) of the quota the client goes DEGRADED — which is a state
   change and therefore mails the alert address.

## 4. Backups (per tenant, restore-tested, off-host-ready)

Rootless podman is per-user: a backup job running as one account cannot even
see another account's containers. Fleet backups therefore run as **root**,
driven by the same per-host client registry the monitor uses
(`/etc/octbase/clients.d/*.conf`):

- `backup-fleet.sh` (daily systemd timer, per host) — for every registered
  client: `pg_dump -Fc` from inside the client's own podman context, a
  **mandatory restore test** into a throwaway Postgres (same major version,
  contract C11), plus a tar of attachments + `.env`; per-client retention
  pruning; loud non-zero exit on any failure.
- Off-host copy: `backup_offhost_cmd` (group_vars → `/etc/octbase/backup.conf`)
  is executed after each run when set (e.g. an `rclone sync` to versioned,
  client-side-encrypted object storage — readiness plan B1). Its failure
  fails the unit.
- The legacy `backup/backup-octbase.sh` (claude account) keeps covering the
  resident dev/demo stacks until they are ledger-managed; client instances
  are the fleet job's business.

## 5. Lifecycle

| Action | Tool |
|---|---|
| Onboard | `ledger.py new` → `create-instance.yml` |
| Reconfigure (edition/seats/version/resources/quota) | edit ledger → `create-instance.yml` (or `set-resources.yml` / `set-max-users.yml` / `set-version.yml` for a single knob) |
| Code update | `sync-instance.yml` (branch) or `create-instance.yml` (working tree) |
| Suspend / resume | `suspend-instance.yml` (status: suspended) / set `status: active` + `create-instance.yml` |
| Move to another **account/domain, same host** | `migrate-instance.yml` |
| Move to another **host** | edit `host:` in the ledger → `migrate-host.yml` |
| Offboard | `remove-instance.yml` |

Cross-host moves stage everything (dump, attachments, `.env` secrets) through
the **admin machine** — hosts never need SSH trust between each other. The
source stack is stopped and left in place until verified, exactly like the
same-host migration.

---

## 6. The update prompt (as executed)

This is the prompt/spec the 2026-07-12 update was built from — kept verbatim
so the intent behind the change set stays reviewable:

> **Role:** Senior DevOps engineer. **Repo:** `octbase-service` (Ansible run
> from an admin machine; production hosts only run podman + systemd).
>
> **Goal:** extend the one-host, one-instance-per-account toolkit into a
> concept and implementation for running and managing many instances of the
> same software across multiple servers. Requirements:
>
> 1. **Multi-host:** the ledger pins each instance to an inventory host
>    (`host:`), validated by `ledger.py`; every per-client playbook scopes
>    itself to that host (assert the host exists, `meta: end_host`
>    elsewhere); host-level installers (monitoring, backup) target all hosts.
>    Ports stay globally unique to keep instances movable.
> 2. **Cross-host migration:** a `migrate-host.yml` playbook that moves an
>    instance to the host in its (updated) ledger entry: freeze + dump +
>    verify on the source, stage DB/attachments/`.env` to the admin machine,
>    provision the target via the existing idempotent `create-instance.yml`,
>    restore data, carry the data-at-rest secrets (JWT/SCM/MFA — same set as
>    the same-host migration), health-gate, deregister the source
>    (monitor + edge snippet), keep source data as safety copy, print the
>    DNS repoint step.
> 3. **Resource give/take:** ledger `resources:` block → systemd user-slice
>    drop-in (MemoryMax/CPUQuota/TasksMax) with platform defaults; a
>    `set-resources.yml` playbook to change allocations without a redeploy;
>    drop-in removed on offboarding.
> 4. **Disk quota:** ledger `disk_quota_gb`; enforce with `setquota` where
>    the filesystem supports it (warn where not), and always feed the quota
>    into monitoring.
> 5. **Disk monitoring:** the fleet monitor reports per-instance disk usage
>    (cached `du`, hourly) in `status.json` and alerts (state-change mail)
>    when usage crosses the alert threshold of the quota.
> 6. **Backup automation per tenant:** a root-level, registry-driven
>    `backup-fleet.sh` + daily timer per host (`install-backup.yml`):
>    `pg_dump -Fc` per client + restore test (throwaway Postgres, same major
>    version) + attachments/`.env` tar + retention + optional off-host sync
>    hook; loud failure via systemd.
> 7. **Suspend:** `suspend-instance.yml` — stop + disable the stack of a
>    `status: suspended` client, deregister monitoring, replace its edge
>    vhost with a 503 responder; resume = `status: active` +
>    `create-instance.yml`.
> 8. **Hygiene:** keep the ledger secret-free; keep all new tasks on FQCN
>    modules and current (non-deprecated) Ansible idioms; fix the README's
>    Ansible version claim (`ansible.builtin.systemd_service` requires
>    ansible-core ≥ 2.15); update README/CLAUDE.md/register/readiness plan
>    and the ledger sample in the same change; everything validated with the
>    `playbook-check` procedure (no Ansible on this host).

## 7. Deliberate non-goals (for now)

- **HA / shared state across hosts** — out of scope until the triggers in
  the app repo's `hosting-concept.md` §14 fire; an instance lives on exactly
  one host.
- **Automatic DNS** — records are created/repointed manually; playbooks
  print the exact step.
- **Registry-based image distribution** — still the readiness plan's S3
  (per-client builds remain the deploy path meanwhile).
- **Per-service (container) resource knobs in the ledger** — the account
  slice is the platform's allocation unit; per-service limits belong to the
  app repo's compose files.
