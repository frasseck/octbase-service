---
name: fleet-health
description: Check the live state of the ocete.ch platform host — fleet monitoring, nightly backups, resident stacks, client instances. Use when asked whether backups/monitoring/clients are healthy, to investigate a monitoring alert, or before/after a rollout as a health gate.
---

# Fleet health — live host state

This checkout sits **on the production host**, so host state is directly
inspectable. Read-only commands below are always safe; anything that
starts/stops/restarts a stack needs an explicit ask.

**Known state as of 2026-07-11:** no clients onboarded; fleet monitoring
**not installed** (`/etc/octbase` and `/var/lib/octbase-monitor` don't exist
— installing it is launch blocker B2 in `docs/production-readiness-plan.md`
and needs `install-monitoring.yml` from the admin machine); the nightly
backup **is live** (`octbase-backup.timer`, 03:30, with automated restore
test). Update this paragraph when it changes.

## Backups (live today)

```bash
systemctl --user list-timers | grep octbase-backup   # next/last run
tail -20 ~/backups/backup.log                        # per-run log; ends "backup run completed OK"
ls -lt ~/backups/*/ | head                           # dumps per stack (octbase_postgres_1, octbase_dev_postgres_1)
```

A healthy run logs a **restore test OK** line per stack (throwaway Postgres,
table + user count compared to source). No restore-test line, or a missing
day, is a finding. This job covers only the `claude` account's resident
stacks (rootless podman is per-user).

## Fleet backups (client instances; once installed via install-backup.yml)

```bash
systemctl list-timers | grep octbase-fleet-backup      # root timer, daily 04:00
tail -20 /var/backups/octbase/fleet/backup.log         # per-run log; restore test per client
journalctl -u octbase-fleet-backup.service -n 50
```

Per client: `pg_dump -Fc` + restore test + attachments/`.env` tar under
`/var/backups/octbase/fleet/<name>/`. Off-host sync runs only when
`backup_offhost_cmd` is set (readiness plan B1 — "not configured" in the log
is a known open item, not a failure).

## Fleet monitor (once installed)

```bash
sudo /usr/local/lib/octbase/monitor-all.sh --print   # ad-hoc fleet status
cat /var/lib/octbase-monitor/status.json             # machine-readable: OK|DEGRADED|DOWN + disk_bytes/disk_pct per client
journalctl -u octbase-monitor.service -n 50          # runs every 5 min; alerts on state change
ls /etc/octbase/clients.d/                           # registered clients (maintained by playbooks)
```

Alert mail goes to `alert_email` in `inventory/group_vars/all.yml` ("" =
journal only). A client pending DNS/edge can have `monitor_edge_probe: false`
in its ledger file.

## Per-stack diagnosis

```bash
podman ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'   # resident stacks (claude user)
```

| Stack | Where to diagnose |
|---|---|
| A client instance | `sudo machinectl shell oct-<name>@` (or ssh) → then the app repo's probe: `~octbase/octbase-operations/check-health.sh`; public edge: `curl -s https://<name>.ocete.ch/health` |
| Demo (`octbase` project) | `~/demo.ocete.ch` checkout → its `stack-health` skill |
| Dev (`octbase_dev` project) | `~/dev.ocete.ch` checkout → its `stack-health` skill |
| Marketing site | `~/ocete.ch` checkout → its `run-site` skill |

The reaction runbook (which layer failed, what to do) is the app repo's
`octbase-operations/README.md`; don't duplicate it here.

## Post-rollout gate

After `create-instance.yml` runs for a client (the playbook already waits on
`/health`), confirm from here:

```bash
curl -s https://<name>.ocete.ch/health        # through the public edge
sudo /usr/local/lib/octbase/monitor-all.sh --print   # once monitoring is installed
```

## Related

- Onboarding/reconfiguring the client whose stack you're probing → `client-ops`
- Health-contract changes (endpoint, container names) → `consistency-check` (C6/C7)
