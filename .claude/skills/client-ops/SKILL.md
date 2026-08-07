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
    --max-users 25 --contact it@acme.example
./ledger/ledger.py validate
git add ledger/clients/acme.yml && git commit -m "ledger: onboard acme"
# admin machine:
ansible-playbook playbooks/create-instance.yml -e client=acme
```

`create-instance.yml` also onboards on its own: run it for a client with no
ledger entry and its first play asks for every field, then calls the same
`ledger.py new` and validates the ledger before provisioning. Use it for an
interactive onboarding; use the form above when scripting, and when you already
know the answers. The entry is written **uncommitted** either way — commit it.
The dialog needs a terminal and refuses to run under `--check`.

Constraints encoded in `ledger.py` (don't work around them): name =
`^[a-z][a-z0-9-]{1,27}$`, not in the reserved set (`www dev mail api
octbase admin` — `demo` is a ledger-managed instance since 2026-07-11);
`jira_import` booked by default on every edition since 2026-08-07
(`--no-jira-import` to opt out) — but the running app still refuses the import
on `team` (403, menu hidden), so a team client books what it does not yet get;
that gap is tracked as drift under C3. Ports auto-allocated from 8110 in
blocks of 10.

Then two **manual** steps the playbook prints: DNS A/AAAA record for
`acme.octbase.io`, and including the generated edge snippet
(`/etc/octbase/edge/acme.caddy`) from the root-managed edge Caddyfile.
While DNS/edge are pending, set `monitor_edge_probe: false` in the ledger
file (remove it once live). Verify: `curl -s https://acme.octbase.io/health`.

## Reconfigure (edition, add-on, seats, version)

Edit the ledger file → `validate` → commit → re-run
`create-instance.yml -e client=<name>` (idempotent; re-applies ledger- and
platform-managed settings, never touches secrets or data).

`reconfigure-instance.yml -e client=<name>` does all of that interactively:
shows each current value, asks for each (empty keeps it), writes via
`ledger.py set` — a line edit, so comments and `notes` survive — then re-runs
the setup. It refuses a non-active client and will not change `name`, `host`,
`status` or `ports`; those belong to migrate-instance / migrate-host /
suspend-remove / the allocator. It also measures the account's real disk usage
and **warns + pauses if the new quota is below it** (setquota's hard limit does
not shrink an account, it makes the next write fail). Non-interactive
equivalent: `ledger.py set <name> --edition … --max-users …`.

Seats only:
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
2. Verify the deploy source: `git -C ~/test.octbase.io status -sb` must show the
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
`~/octbase` (same excludes as create), refreshes the compose override, then
**always** rebuilds, restarts and gates on `/health`. App code is baked into
the images at build time, so **every run restarts the stack** — re-running on
the branch tip is not a no-op, it is another brief outage. Constraints an agent
must respect:

- **Update-only.** It refuses an unprovisioned instance and never touches
  secrets, data, ports, or ledger-managed settings — the one `.env` line it
  writes is the version stamp (below). Provision with `create-instance.yml`
  first. A suspended/removed client is **not skipped — the run fails** on the
  `status == 'active'` assert, which matters when looping over a host.
- **Re-stamps the version from the ledger.** `OCTBASE_APP_VERSION` is
  re-applied from `app_version` (falling back to `octbase_version`) on every
  run, so a sync cannot leave the stamp behind the code (C4). The ledger stays
  the source of truth: to change the stamp, edit the ledger entry *before*
  syncing — there is no `-e app_version=` override.
- **Schema direction.** Make sure the branch is at or above the instance's
  running DB schema version before syncing — a downgrade is not handled.
- Not a substitute for the release rollout when a client must be on a
  *stamped, reviewed* release; use `create-instance.yml` for that.

## Sync every instance on one host

There is **no `sync-host.yml`**. `sync-instance.yml` is one client per run, so
fan-out is a shell loop over the ledger — the same model as the release rollout
above. Enumerate, then loop:

```bash
# admin machine — every ACTIVE client pinned to prod01
clients=$(./ledger/ledger.py list --host prod01 --status active --names-only) || exit 1
for c in $clients; do
    ansible-playbook playbooks/sync-instance.yml -e client="$c" || break
done
```

- `--names-only` prints one name per line; `--host` is validated against
  `inventory/hosts.yml`, and a selection that matches nothing **exits
  non-zero** — hence `|| exit 1`. Without it an empty list makes the loop a
  silent no-op that reads as a clean sweep.
- `|| break` is the chosen failure policy: **stop at the first failure**, leave
  the remaining clients on their old code. Do not quietly change this to
  `continue` — a bad branch would then be pushed to every instance on the host.
- Each iteration is a full sync: rebuild, restart, health gate. The host takes
  one brief outage per instance, serially. Verify afterwards with
  `scripts/check-version-drift.py` and the `fleet-health` skill.
- Not a release path. To put a host's clients on a *stamped* release, loop
  `create-instance.yml` the same way after bumping the ledger.

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
