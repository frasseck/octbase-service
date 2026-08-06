---
name: migrate-instance
description: Move an existing Octbase installation to its own restricted Linux account and/or a new domain — adopt a legacy shared-account stack (e.g. the public demo) into the client model, or rename a managed client. Use when asked to move/migrate/rename an installation, give an instance its own user, or take over a domain in the edge Caddy.
---

# Migrate an installation to a new user / domain

`playbooks/migrate-instance.yml` moves a **running Octbase installation**
onto a dedicated restricted account (`oct-<name>`) with everything the
standard client model provides: rootless podman, loopback-only ports, a
`systemd --user` unit, fresh `.env`, monitor registration, and an edge
snippet — and it **edits the root-managed edge Caddyfile** (the one place
that is allowed to): it ensures `import /etc/octbase/edge/*.caddy` is
present and retires the source domain's hardcoded vhost block, then
validates and reloads Caddy.

Two use cases, same playbook:
- **Adopt a legacy stack** (runs in a shared account, no systemd unit,
  hardcoded edge vhost) into the client model — e.g. the public demo.
- **Rename a managed client**: `oct-old`/`old.octbase.io` →
  `oct-new`/`new.octbase.io` (new ledger entry under the new name; the old
  snippet + monitor registration are dropped automatically).

## How it works (3 phases, one invocation)

1. **Dump & stop the source** — asks interactively for the source domain,
   account, and path (or takes them via `-e`), freezes writes (stops the
   API container), `pg_dump`s the database (verified complete), stages
   `.env` + `attachments/` into a root-only workspace under
   `/var/backups/octbase/` (kept afterwards as the safety copy), then
   brings the source stack down. **The source data is never deleted.**
2. **`create-instance.yml` runs unchanged** — provisions the target from
   its ledger entry like any new client.
3. **Restore & cut over** — carries `OCTBASE_JWT_SECRET`,
   `OCTBASE_SCM_ENC_KEY`, `OCTBASE_MFA_ENC_KEY` from the source `.env`
   (data at rest is unreadable under fresh keys; `POSTGRES_PASSWORD` is
   deliberately *not* carried), drops the fresh DB and restores the dump,
   restores attachments, restarts, gates on `/health`, then switches the
   edge and reloads Caddy.

## Invocation (admin machine)

```bash
# Target = a normal ledger entry; create it first if adopting:
./ledger/ledger.py new <name> --edition … --max-users … && ./ledger/ledger.py validate
git add ledger/clients/<name>.yml && git commit -m "ledger: onboard <name> (migration)"

ansible-playbook playbooks/migrate-instance.yml -e client=<name>
# prompts: source domain, source account, source path, confirmation
# unattended: -e source_fqdn=… -e source_user=… -e source_dir=… -e confirm=<name>
```

## Constraints and safety rules

- **Downtime**: the source is stopped in phase 1 and the target only serves
  after build + restore (minutes). Announce it for anything client-facing.
- **Schema direction**: the target's code comes from `octbase_src` on the
  admin machine (contract C13 — released commit, clean tree). Its migration
  version must be **≥** the source's; the API migrates the restored dump up
  on start. Never migrate onto older code.
- The playbook refuses to run phase 3 standalone, refuses source == target,
  and requires typing the target name to confirm the stop.
- **After verification** (browser login, projects, pages, attachments):
  remove the stopped source checkout manually, remove whatever started it
  (cron, `restart.sh`, …), prune the workspace under `/var/backups/octbase/`,
  and update platform docs that name the old location
  (`docs/platform-overview.md`, `docs/consistency-register.md` C8/C9/C15).
- DNS is manual as always; only needed when the domain actually changes.
- Rollback before the edge cutover = restart the source
  (`podman-compose up -d` in the source dir); the edge config is only
  touched in the final tasks of phase 3.

## Worked example: demo.ocete.ch → oct-demo (done 2026-07-11)

Kept because it is the only end-to-end run of this playbook, not because
anything is outstanding. **The migration is complete**: the demo is a
ledger-managed client (`ledger/clients/demo.yml`, ports 8110-8112,
enterprise), it runs under `oct-demo`, and the legacy
`/home/claude/demo.ocete.ch` checkout has been removed — the old stack's
ports 8080/8000/5432 stay in `RESERVED_PORTS` regardless.

```bash
ansible-playbook playbooks/migrate-instance.yml -e client=demo
#   Domain to move:  demo.ocete.ch
#   Account:         claude
#   Path:            /home/claude/demo.ocete.ch      # no longer exists
```

What the run needed afterwards, worth knowing for the next migration:

1. **Demo mode**: the client model writes `OCTBASE_DEMO_MODE=false`; the demo
   needs it **true** (seeded demo logins). As `oct-demo`:
   `sed -i 's/^OCTBASE_DEMO_MODE=.*/OCTBASE_DEMO_MODE=true/' ~/octbase/.env
   && systemctl --user restart octbase` — the client compose override passes
   it through with a fail-closed default.
2. Same domain, so **no DNS change** — verify `https://demo.ocete.ch/health`
   and a real login through the edge.
3. **The release process had to move with it.** The app repo's `release`
   skill used to deploy the demo by pulling into that checkout; with the
   checkout gone the demo deploys like any client, from the admin machine
   (`sync-instance.yml -e client=demo`, or `set-version.yml` for a tagged
   release). A migration is not finished until whatever used to deploy the
   old location has been repointed.

## Related

- Onboard/reconfigure/offboard → `client-ops`
- Validating the playbook edits before shipping → `playbook-check`
- Post-migration contract review → `consistency-check`
