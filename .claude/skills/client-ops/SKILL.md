---
name: client-ops
description: Onboard, reconfigure, or offboard an Octbase client instance, or roll a release out to clients — ledger workflow, playbook invocations, manual DNS/edge steps, safety rules. Use when asked to add/change/suspend/remove a client, change edition/seats/add-ons/version, or deploy a release to client instances.
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
  credentials into `ledger/clients/*.yml` or `group_vars/all.yml`.
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
`^[a-z][a-z0-9-]{1,27}$`, not in the reserved set (`www dev demo mail api
octbase admin`); `jira_import` only bookable on `business` (included in
enterprise, never on team); ports auto-allocated from 8110 in blocks of 10.

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

Changing a platform-wide value in `inventory/group_vars/all.yml` (SMTP,
trusted proxies, retention) requires re-running `create-instance.yml` for
**every active client**.

## Roll out a release to clients

Prerequisite: the app release is done (app repo `release` skill) and the demo
is deployed. Then, in this repo:

1. Bump `octbase_version` in `inventory/group_vars/all.yml` (and/or
   `app_version` per ledger entry) — must match a dated entry in the app
   repo's `CHANGELOG.md` (contract C4).
2. Verify the deploy source: `git -C ~/dev.ocete.ch status -sb` must show the
   released commit with a **clean tree** — the playbook rsyncs the working
   tree as-is, uncommitted changes included (contract C13).
3. Admin machine: `create-instance.yml` per active client; the playbook gates
   on `/health`.
4. Run the `consistency-check` skill (register §3) after the release.

## Suspend / offboard

- `status: suspended` in the ledger blocks `create-instance.yml`, but no
  playbook stops a running stack yet — that is manual
  (`systemctl --user stop octbase` as the client user; known gap).
- Offboard: `remove-instance.yml -e client=acme -e confirm=acme`, then
  manually remove DNS, reload the edge, and set `status: removed` in the
  ledger file — **keep the file** (historical record).

## Related

- Validating playbook/template edits before they ship → `playbook-check`
- Cross-repo contract review after changes → `consistency-check`
- Fleet/monitoring/backup state → `fleet-health`
