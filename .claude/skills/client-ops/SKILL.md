---
name: client-ops
description: Onboard, reconfigure, or offboard an Octbase client instance, roll a release out to clients, or sync an instance's code to an app-repo branch — ledger workflow, playbook invocations, manual DNS/edge steps, safety rules. Use when asked to add/change/suspend/remove a client, change edition/seats/add-ons/version, deploy a release to client instances, or sync/update an instance to main.
---

# Client lifecycle operations

The authoritative runbooks live in the [README](../../../README.md#runbooks);
this skill condenses them and adds the constraints an agent must respect.

**Known state as of 2026-07-11:** no client has ever been onboarded
(`ledger/clients/` holds only the sample), fleet monitoring is not installed
(`/etc/octbase` missing), and **Ansible is not installed on this host** —
playbooks run from an admin machine. From this checkout you can prepare
everything (ledger entry, committed config) but not execute the playbooks;
say so instead of improvising. If a check shows this paragraph is stale,
update it.

## Ground rules

- Every lifecycle change starts in the ledger: edit/scaffold the client file,
  `./ledger/ledger.py validate`, commit — *then* the playbook run applies it.
  Never leave the ledger diverging from what was applied (extra-vars beat the
  ledger; if an override was used, sync the ledger afterwards).
- The ledger holds no secrets — never write passwords, JWT secrets, or SMTP
  credentials into `ledger/clients/*.yml` or `group_vars/all/main.yml`.
- `remove-instance.yml` deletes the Linux account and all data. It requires
  `-e confirm=<name>` and takes a final backup by default; never suggest
  `skip_backup=true` unless the user explicitly wants that.

## Onboard

```bash
./ledger/ledger.py new acme --display "ACME GmbH" --edition business \
    --jira-import --max-users 25 --contact it@acme.example
./ledger/ledger.py validate
git add ledger/clients/acme.yml && git commit -m "ledger: onboard acme"
# admin machine:
ansible-playbook playbooks/create-instance.yml -e client=acme
```

Constraints encoded in `ledger.py` (don't work around them): name =
`^[a-z][a-z0-9-]{1,27}$`, not in the reserved set (`www dev mail api
octbase admin` — `demo` is a ledger-managed instance since 2026-07-11);
`jira_import` only bookable on `business` (included in enterprise, never on
team); ports auto-allocated from 8110 in blocks of 10.

Then two **manual** steps the playbook prints: DNS A/AAAA record for
`acme.ocete.ch`, and including the generated edge snippet
(`/etc/octbase/edge/acme.caddy`) from the root-managed edge Caddyfile.
While DNS/edge are pending, set `monitor_edge_probe: false` in the ledger
file (remove it once live). Verify: `curl -s https://acme.ocete.ch/health`.

## Reconfigure (edition, add-on, seats, version)

Edit the ledger file → `validate` → commit → re-run
`create-instance.yml -e client=<name>` (idempotent; re-applies ledger- and
platform-managed settings, never touches secrets or data). Seats only:
`set-max-users.yml` (restarts the stack — brief downtime). Upload/storage
limits (`OCTBASE_MAX_UPLOAD_MB`, `OCTBASE_MAX_USER_STORAGE_MB`) are
deliberately **not** ledger-managed — one-off deals are edited in the
client's `.env` on the server and the stack restarted.

Changing a platform-wide value in `inventory/group_vars/all/main.yml` (SMTP,
trusted proxies, retention) requires re-running `create-instance.yml` for
**every active client**.

## Roll out a release to clients

Prerequisite: the app release is done (app repo `release` skill) and the demo
is deployed. Then, in this repo:

1. Bump `octbase_version` in `inventory/group_vars/all/main.yml` (and/or
   `app_version` per ledger entry) — must match a dated entry in the app
   repo's `CHANGELOG.md` (contract C4).
2. Verify the deploy source: `git -C ~/dev.ocete.ch status -sb` must show the
   released commit with a **clean tree** — the playbook rsyncs the working
   tree as-is, uncommitted changes included (contract C13).
3. Admin machine: `create-instance.yml` per active client; the playbook gates
   on `/health`.
4. Run the `consistency-check` skill (register §3) after the release.

This is the **release** path — a version-stamped rollout from the reviewed
`octbase_src` working tree, which also re-applies ledger/platform `.env`
settings. For pulling an instance straight from a branch tip, use the sync path
below instead.

## Sync an instance to a branch (main)

`sync-instance.yml` deploys `octbase_branch` (default `main`, from
`octbase_repo` in `group_vars/all/main.yml`) of the app repo instead of the
`octbase_src` working tree — the git-branch deploy path (register C13b),
distinct from the release rollout above.

```bash
# admin machine — sync the demo (/home/oct-demo/octbase) to origin/main
ansible-playbook playbooks/sync-instance.yml -e client=demo
ansible-playbook playbooks/sync-instance.yml -e client=demo -e octbase_branch=release_v15
```

Clones/updates the branch into a cache **on the admin machine**, rsyncs it into
`~/octbase` (same excludes as create), refreshes the compose override, and —
**only if the source changed** — rebuilds, restarts, gates on `/health`.
Re-running on the branch tip is a no-op. Constraints an agent must respect:

- **Update-only.** It refuses an unprovisioned instance and never touches
  secrets, data, ports, or ledger-managed settings — the one `.env` line it
  writes is the version stamp (below). Provision with `create-instance.yml`
  first; suspended/removed clients are skipped (`status == 'active'` assert).
- **Re-stamps the version from the ledger.** `OCTBASE_APP_VERSION` is
  re-applied from `app_version` (falling back to `octbase_version`) on every
  run, so a sync cannot leave the stamp behind the code (C4). The ledger stays
  the source of truth: to change the stamp, edit the ledger entry *before*
  syncing — there is no `-e app_version=` override.
- **Schema direction.** Make sure the branch is at or above the instance's
  running DB schema version before syncing — a downgrade is not handled.
- Not a substitute for the release rollout when a client must be on a
  *stamped, reviewed* release; use `create-instance.yml` for that.

## Suspend / offboard

- Suspend: set `status: suspended` in the ledger (commit), then
  `suspend-instance.yml -e client=acme -e confirm=acme` — stops + disables
  the stack non-destructively, deregisters monitoring, serves 503 at the
  edge (manual edge reload afterwards). Resume: `status: active` +
  `create-instance.yml` + edge reload. Suspended instances drop out of the
  nightly fleet backup — suggest a final manual backup when the suspension
  may end in offboarding.
- Offboard: `remove-instance.yml -e client=acme -e confirm=acme`, then
  manually remove DNS, reload the edge, and set `status: removed` in the
  ledger file — **keep the file** (historical record).

## Resources / disk quota

Account-level caps (memory/CPU/tasks via the systemd user slice) and the
disk quota live in the ledger (`resources:` block, `disk_quota_gb`; defaults
in group_vars). Apply without a redeploy:
`set-resources.yml -e client=acme` (extra-vars `memory_max=`/`cpu_quota=`/
`tasks_max=`/`disk_quota_gb=` override ad-hoc — remind the user to update
the ledger afterwards). The monitor alerts at 90% of the disk quota.

## Move / rename

Moving an installation to its own account and/or a new domain **on the same
host** (including adopting the legacy demo stack) is `migrate-instance.yml`
— see the `migrate-instance` skill. Moving an instance to **another host**
is `migrate-host.yml`: edit `host:` in the ledger first, then
`-e client=<name> -e source_host=<old> -e confirm=<name>`
(README runbook + `docs/fleet-concept.md`). Neither is a manual procedure.

## Related

- Moving/renaming an instance, demo adoption → `migrate-instance`
- Validating playbook/template edits before they ship → `playbook-check`
- Cross-repo contract review after changes → `consistency-check`
- Fleet/monitoring/backup state → `fleet-health`
